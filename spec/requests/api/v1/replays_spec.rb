# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Replays (ingest bearer)", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  # session_replay_enabled: true → l'ingest è gata dal toggle opt-in (default false).
  let(:project) { create(:project, organization:, session_replay_enabled: true) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(
      project:, name: "Browser", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:headers) do
    { "Authorization" => "Bearer #{secret}", "CONTENT_TYPE" => "application/json" }
  end

  def chunk(over = {})
    { "replay_session_id" => "sess-abc", "seq" => 0, "started_at" => Time.current.iso8601,
      "environment" => "production", "events" => [ { "type" => 2 }, { "type" => 3 } ] }.merge(over)
  end

  it "bearer valido + array → 202 { data: { accepted } } e un solo IngestJob" do
    body = [ chunk("seq" => 0), chunk("seq" => 1) ]
    expect do
      post "/api/v1/projects/#{project.id}/replays", params: body.to_json, headers: headers
    end.to have_enqueued_job(Replays::IngestJob).once

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(2)
  end

  it "accetta anche un singolo chunk" do
    post "/api/v1/projects/#{project.id}/replays", params: chunk.to_json, headers: headers
    expect(response.parsed_body.dig("data", "accepted")).to eq(1)
  end

  it "end-to-end: il job crea la sessione e allega il chunk gzippato" do
    # allow_n_plus_one: ActiveStorage fa un SELECT attachment per-blob durante un attach multiplo
    # (comportamento framework su N chunk in un batch, non un N+1 di produzione da ottimizzare).
    allow_n_plus_one do
      perform_enqueued_jobs do
        post "/api/v1/projects/#{project.id}/replays",
             params: [ chunk("seq" => 0), chunk("seq" => 1) ].to_json, headers: headers
      end
    end

    expect(project.replay_sessions.count).to eq(1)
    session = project.replay_sessions.first
    expect(session.replay_session_id).to eq("sess-abc")
    expect(session.chunks.attached?).to be(true)
    expect(session.chunks.count).to eq(2)
    expect(session.events_count).to eq(4) # 2 eventi × 2 chunk
  end

  it "toggle OFF → 202 accepted:0 senza enqueue" do
    project.update!(session_replay_enabled: false)
    expect do
      post "/api/v1/projects/#{project.id}/replays", params: chunk.to_json, headers: headers
    end.not_to have_enqueued_job(Replays::IngestJob)

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(0)
  end

  it "batch oltre soglia → R413" do
    body = Array.new(Replays::Constants::MAX_BATCH + 1) { chunk }
    post "/api/v1/projects/#{project.id}/replays", params: body.to_json, headers: headers

    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body.dig("error", "code")).to eq("R413-REPLAY-002")
  end

  it "nessun chunk valido nel batch → R422" do
    body = [ chunk("events" => []), chunk("replay_session_id" => "") ]
    post "/api/v1/projects/#{project.id}/replays", params: body.to_json, headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-REPLAY-004")
  end

  it "BOLA: project_id del path diverso da quello del token → 404 R404-REPLAY-001" do
    other = create(:project, organization:, session_replay_enabled: true)
    post "/api/v1/projects/#{other.id}/replays", params: chunk.to_json, headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-REPLAY-001")
  end

  it "senza token → 401" do
    post "/api/v1/projects/#{project.id}/replays", params: chunk.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end
end
