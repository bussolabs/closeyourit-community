# frozen_string_literal: true

require "rails_helper"

# CYAU-282 — the machine running an attempt sends the agent's steps while it works.
RSpec.describe "Api::V1::Agents::AttemptLiveEvents", type: :request do
  let(:organization) { create(:organization) }
  let(:registration) do
    Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-1", platform: "linux", arch: "amd64"
    ).value
  end
  let(:host) { registration.fetch(:host) }
  let(:headers) { { "Authorization" => "Bearer #{registration.fetch(:secret)}" } }
  let(:workflow) { create(:agent_workflow, organization:, triage_started_at: Time.current) }
  let(:attempt) { create(:agent_attempt, workflow:, organization:, host:, phase: "triage", status: :running) }
  let(:path) { "/api/v1/agent_attempts/#{attempt.id}/live_events" }
  let(:events) do
    [ { seq: 1, at: "2026-11-02T15:00:00Z", event: { kind: "file_read", path: "app/models/ticket.rb" } } ]
  end

  it "stores the steps and answers how far it got and whether code is kept" do
    post path, params: { events: }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]).to eq("accepted_through" => 1, "include_code" => false)
    expect(attempt.live_events.count).to eq(1)
  end

  it "needs the host token" do
    post path, params: { events: }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it "does not find an attempt of another organization" do
    foreign = create(:agent_attempt, organization: create(:organization), phase: "triage", status: :running)

    post "/api/v1/agent_attempts/#{foreign.id}/live_events", params: { events: }, headers:, as: :json

    expect(response).to have_http_status(:not_found)
  end

  it "refuses a host that is not running the attempt" do
    theirs = create(:agent_attempt, workflow:, organization:, host: create(:agent_host, organization:),
                                    phase: "triage", status: :running)

    post "/api/v1/agent_attempts/#{theirs.id}/live_events", params: { events: }, headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-LIVE-001")
  end

  it "refuses a batch out of shape" do
    post path, params: { events: [ { seq: 1, at: "2026-11-02T15:00:00Z", event: { kind: "shell" } } ] }, headers:, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-LIVE-001")
  end

  it "refuses a request that is too large before reading it" do
    huge = Array.new(200) { |index| { seq: index + 1, at: "2026-11-02T15:00:00Z", event: { kind: "command", command: "x" * 3000 } } }

    post path, params: { events: huge }, headers:, as: :json

    expect(response).to have_http_status(:content_too_large)
    expect(attempt.live_events).to be_empty
  end
end
