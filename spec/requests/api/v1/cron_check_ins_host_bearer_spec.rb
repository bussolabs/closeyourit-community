# frozen_string_literal: true

require "rails_helper"

# CYRA-182: il daemon Automator autentica il check-in con il proprio token Agent Host (cyi_ah_), non con
# un token ingest di progetto. Prima di questo fix `resolve_bearer_token` cercava il digest solo tra i
# Projects::Token, quindi ogni battito moriva con 401 — e l'heartbeat, best-effort lato client, ingoiava
# la risposta: nessun monitor, host offline per sempre, nessuna riga di log da nessuna parte.
RSpec.describe "Api::V1::CronCheckIns (bearer Agent Host)", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let(:host) { create(:agent_host, organization:) }
  let(:plain) { "cyi_ah_#{SecureRandom.hex(16)}" }
  let!(:host_token) { create(:agent_host_token, host:, token_digest: Digest::SHA256.hexdigest(plain)) }
  let(:headers) { { "Authorization" => "Bearer #{plain}" } }

  it "il battito autenticato col token host crea il monitor → 202" do
    expect do
      post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:,
           params: { status: "ok" }, as: :json
    end.to change(project.cron_monitors, :count).by(1)

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "slug")).to eq("automator-minion-1")
  end

  it "attribuisce la telemetria all'host DEL TOKEN, ignorando un host_id ostile nel body" do
    intruder = create(:agent_host, organization:)

    post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:,
         params: { status: "ok", host_id: intruder.id, automator_version: "0.9.1" }, as: :json

    expect(response).to have_http_status(:accepted)
    expect(host.reload.last_heartbeat_at).to be_present
    expect(host.automator_version).to eq("0.9.1")
    expect(intruder.reload.last_heartbeat_at).to be_nil
  end

  it "saves the last stops sent with the heartbeat (CYRA-999)" do
    post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:,
         params: { status: "ok", last_stops: [ { action: "lab", state: "waiting", reason: "empty ticket queue" } ] },
         as: :json

    expect(response).to have_http_status(:accepted)
    expect(host.reload.last_stops).to eq([ { "action" => "lab", "state" => "waiting", "reason" => "empty ticket queue" } ])
  end

  it "saves the remaining quota of each engine sent with the heartbeat (CYRA-1177)" do
    quota = [ { runtime: "claude", remaining_percent: 42, resets_at: "2026-11-03T15:00:00.000Z", paused_until: nil },
              { runtime: "codex", remaining_percent: nil, resets_at: nil, paused_until: "2026-11-03T12:00:00.000Z" } ]

    post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:,
         params: { status: "ok", agent_quota: quota }, as: :json

    expect(response).to have_http_status(:accepted)
    expect(host.reload.agent_quota).to eq(quota.map(&:deep_stringify_keys))
  end

  it "rejects a malformed quota report with 422 (CYRA-1177)" do
    post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:,
         params: { status: "ok", agent_quota: [ { runtime: "claude", remaining_percent: 140, resets_at: nil, paused_until: nil } ] },
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "details").keys).to include("agent_quota.0")
    expect(host.reload.agent_quota).to eq([])
  end

  it "keeps accepting heartbeats from automators that do not send the quota (CYRA-1177)" do
    post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:,
         params: { status: "ok", automator_version: "0.47.1" }, as: :json

    expect(response).to have_http_status(:accepted)
    expect(host.reload.agent_quota).to eq([])
  end

  # CYRA-1178 — a reduced heartbeat sent while the automator event loop is blocked.
  describe "hang report" do
    let(:hang) { { state: "hung", started_at: 3.minutes.ago.utc.iso8601, duration_seconds: 180 } }

    it "stores the hang and shows the host as hung, not online" do
      host.update!(host_status: "busy", last_heartbeat_at: 2.minutes.ago)

      post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:,
           params: { status: "fail", automator_version: "0.48.0", hang: hang.merge(secret: "x") }, as: :json

      expect(response).to have_http_status(:accepted)
      expect(host.reload.hang).to include("state" => "hung", "duration_seconds" => 180)
      expect(host.hang).not_to have_key("secret")
      expect(host.activity_status).to eq("hung")
    end

    it "raises no alert for the reduced heartbeat" do
      expect do
        post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:,
             params: { status: "fail", automator_version: "0.48.0", hang: }, as: :json
      end.not_to have_enqueued_job(Alerting::EvaluateJob)

      expect(response).to have_http_status(:accepted)
    end

    it "rejects a malformed hang report → 422" do
      post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:,
           params: { status: "fail", hang: hang.merge(state: "frozen") }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(host.reload.hang).to be_nil
    end
  end

  it "un host revocato non batte → 401" do
    host.update!(revoked_at: Time.current)

    post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it "un token host revocato non batte → 401" do
    host_token.update!(revoked_at: Time.current)

    post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in", headers:, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it "anti-BOLA: un progetto di un'ALTRA organizzazione non è battibile → 404" do
    foreign = create(:project, organization: create(:organization), key: "OTH")

    expect do
      post "/api/v1/projects/#{foreign.id}/crons/automator-minion-1/check_in", headers:, as: :json
    end.not_to change(Crons::Monitor, :count)

    expect(response).to have_http_status(:not_found)
  end

  it "un bearer sconosciuto resta 401 e non crea monitor" do
    expect do
      post "/api/v1/projects/#{project.id}/crons/automator-minion-1/check_in",
           headers: { "Authorization" => "Bearer cyi_ah_inesistente" }, as: :json
    end.not_to change(Crons::Monitor, :count)

    expect(response).to have_http_status(:unauthorized)
  end
end
