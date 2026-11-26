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

  it_behaves_like "private ingest boundary", "replays", Replays::IngestJob, Replays::Ingest::Record, :call, false do
    let(:privacy_payload) do
      chunk("user" => privacy_email, "path" => "/#{privacy_marker}?auth=#{privacy_token}",
            "events" => [ { "type" => 3, "timestamp" => 1234,
                            "data" => { "source" => 5, "id" => 9, "text" => privacy_email } } ])
    end
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

  # CYRA-1210 — the browser SDK masks the recording: the server queues and stores the events as received,
  # so stored sessions and queued jobs keep today's shape. Only the user and the page address change.
  it "stores the events as the browser sent them, with the user hashed and the page query dropped" do
    first = { "type" => 2, "timestamp" => 1000, "data" => { "node" => {
      "type" => 0, "id" => 1, "childNodes" => [ { "type" => 3, "id" => 2, "textContent" => "Checkout" } ]
    }, "initialOffset" => { "top" => 0, "left" => 0 } } }
    second = { "type" => 3, "timestamp" => 1001, "data" => { "source" => 0,
      "texts" => [ { "id" => 2, "value" => "Pay" } ], "attributes" => [], "removes" => [], "adds" => [] } }
    body = [ chunk("seq" => 0, "events" => [ first ], "user" => "user-42", "path" => "/home?ref=mail"),
             chunk("seq" => 1, "events" => [ second ], "user" => "user-42", "path" => "/home") ]
    allow_n_plus_one do
      perform_enqueued_jobs do
        post "/api/v1/projects/#{project.id}/replays", params: body.to_json, headers: headers
      end
    end
    session = project.replay_sessions.sole
    expect(session.user_hash).to eq(Digest::SHA256.hexdigest("user-42")[0, 16])
    expect(session.entry_path).to eq("/home")
    expect(Replays::Read.call(session: session).value).to eq([ first, second ])
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
