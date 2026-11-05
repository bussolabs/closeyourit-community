# frozen_string_literal: true

require "rails_helper"

# CYRA-1197 — the machine asks for the next stopped workflow its supporter should look at, then sends the verdict.
RSpec.describe "Api::V1::AgentHost::SupporterConsults", type: :request do
  let(:organization) { create(:organization) }
  let(:service_account) do
    create(:account, :service).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:plain) { "cyi_ah_plain_supporter_consult_value" }
  let(:headers) { { "Authorization" => "Bearer #{plain}" } }
  let(:project) { create(:project, organization:, supporter_enabled: true) }
  let(:ticket) { create(:ticket, organization:, project:, title: "Sort the list by name", with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }

  before { create(:agent_host_token, host:, token_digest: Digest::SHA256.hexdigest(plain)) }

  def stop!
    workflow.update!(triaged_at: 1.hour.ago, planned_at: 1.hour.ago, approved_at: 1.hour.ago, autopilot_started_at: 1.hour.ago,
                     blocked_at: Time.current, blocked_phase: "autopilot", blocked_kind: "agent_blocked",
                     blocked_reason: "agent_blocked: the test helper is missing")
  end

  it "answers 204 when nothing is stopped" do
    get "/api/v1/agent_host/supporter_consult", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it "serves the stopped workflow and sends it back to the agent on an accepted verdict" do
    stop!

    get "/api/v1/agent_host/supporter_consult", headers: headers
    item = response.parsed_body["data"]
    expect(item).to include("workflow_id" => workflow.id, "project_key" => project.key, "autonomous_max" => 6)
    expect(item["stop"]).to include("kind" => "agent_blocked", "phase" => "autopilot")

    post "/api/v1/agent_host/supporter_consults/#{workflow.id}/verdict", headers: headers, as: :json, params: {
      digest: item["digest"],
      verdict: { recommendation: "retry", guidance: "Use the factory in spec/factories/items.rb instead.", risk_score: 2,
                 confidence: "high", bypass_signals: [], sources: [ "README.md" ], rationale: "r", reasons_against: "a",
                 assumptions: "s", undo: "u" }
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]["outcome"]).to eq("retried")
    expect(workflow.reload.blocked_at).to be_nil
  end

  it "stops the workflow for safety on a stop verdict" do
    stop!
    get "/api/v1/agent_host/supporter_consult", headers: headers

    post "/api/v1/agent_host/supporter_consults/#{workflow.id}/verdict", headers: headers, as: :json, params: {
      digest: response.parsed_body.dig("data", "digest"),
      verdict: { recommendation: "stop", rationale: "Tried to deploy by hand.", bypass_signals: [ "manual_deploy" ],
                 risk_score: 10, confidence: "high" }
    }

    expect(response.parsed_body["data"]["outcome"]).to eq("stopped")
    expect(workflow.reload.blocked_kind).to eq("safety_stop")
  end

  it "refuses a host that no person certified" do
    host.update!(certified_at: nil)

    get "/api/v1/agent_host/supporter_consult", headers: headers
    expect(response).to have_http_status(:forbidden)
  end
end
