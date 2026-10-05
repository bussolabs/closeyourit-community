# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::CronCheckIns (ingest bearer)", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:token) do
    Projects::Tokens::Issue.call(project:, name: "CI", host: "bugs.example.com", environment:).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  it "check-in crea il monitor al primo ping → 202" do
    expect do
      post "/api/v1/projects/#{project.id}/crons/nightly/check_in", headers:,
           params: { name: "Nightly digest", expected_interval_minutes: 30 }
    end.to change(project.cron_monitors, :count).by(1)

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "slug")).to eq("nightly")
  end

  it "check-in ripetuto non duplica il monitor" do
    post "/api/v1/projects/#{project.id}/crons/nightly/check_in", headers: headers
    expect do
      post "/api/v1/projects/#{project.id}/crons/nightly/check_in", headers:, params: { status: "fail" }
    end.not_to change(project.cron_monitors, :count)
    expect(project.cron_monitors.sole.check_ins.count).to eq(2)
  end

  # CYRA-484 — il motivo del fallimento in parole: senza, «fallito» costringeva ad andare a cercarlo
  # nei log dell'applicazione. Facoltativo: un programma che non lo manda continua a funzionare.
  describe "motivo del fallimento" do
    it "arriva col check-in e resta sulla riga" do
      post "/api/v1/projects/#{project.id}/crons/nightly/check_in", headers:,
           params: { status: "fail", reason: "Connessione al database rifiutata" }

      expect(response).to have_http_status(:accepted)
      expect(project.cron_monitors.sole.check_ins.sole.reason).to eq("Connessione al database rifiutata")
    end

    it "senza motivo il check-in funziona come prima" do
      post "/api/v1/projects/#{project.id}/crons/nightly/check_in", headers:, params: { status: "fail" }

      expect(response).to have_http_status(:accepted)
      expect(project.cron_monitors.sole.check_ins.sole.reason).to be_nil
    end

    # Un messaggio lunghissimo non deve far fallire il check-in: si taglia.
    it "un motivo troppo lungo viene tagliato, non rifiutato" do
      post "/api/v1/projects/#{project.id}/crons/nightly/check_in", headers:,
           params: { status: "fail", reason: "x" * 900 }

      expect(response).to have_http_status(:accepted)
      expect(project.cron_monitors.sole.check_ins.sole.reason.length).to eq(Crons::CheckIn::REASON_MAX_CHARS)
    end
  end

  it "senza token → 401" do
    post "/api/v1/projects/#{project.id}/crons/nightly/check_in"
    expect(response).to have_http_status(:unauthorized)
  end

  it "token di un ALTRO progetto → 404 (anti-BOLA)" do
    other = create(:project, organization:)
    post "/api/v1/projects/#{other.id}/crons/nightly/check_in", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  describe "telemetria Agent Host" do
    let(:host) { create(:agent_host, organization:) }
    let!(:mapped_project) { create(:project, organization:, key: "CYAU") }
    let(:active_run) do
      {
        ticket: "CYRA-99", run_id: "run-99", phase: "implementing", runtime: "codex",
        started_at: "2026-07-13T20:00:00.000Z", updated_at: "2026-07-13T20:01:00.000Z",
        lease_expires_at: "2026-07-13T20:05:00.000Z", lease_health: "active", stalled: false,
        token: "must-not-be-saved"
      }
    end
    let(:telemetry) do
      {
        host_id: host.id, automator_version: "0.3.1", platform: "linux", arch: "arm64",
        runtimes: [
          { name: "codex", present: true, version: "codex-cli 1.2.3", required: true,
            bin: "/private/secret/path", token: "must-not-be-saved" }
        ],
        repositories: %w[CYRA CYAU], running: 1, slots: 2,
        host_status: "busy", active_runs: [ active_run ],
        secret: "must-not-be-saved", unknown_capacity: "ignored"
      }
    end

    it "persiste capacità e snapshot dinamico con allowlist, senza segreti, e conserva il monitor cron" do
      freeze_time do
        expect do
          post "/api/v1/projects/#{project.id}/crons/automator-tick/check_in", headers:, params: telemetry, as: :json
        end.to change(project.cron_monitors, :count).by(1)

        expect(response).to have_http_status(:accepted)
        expect(project.cron_monitors.sole.check_ins.count).to eq(1)

        host.reload
        expect(host).to have_attributes(
          automator_version: "0.3.1", platform: "linux", arch: "arm64",
          repositories: %w[CYRA CYAU], running: 1, slots: 2, host_status: "busy",
          last_heartbeat_at: Time.current,
          heartbeat_expected_interval_minutes: 60, heartbeat_grace_minutes: 5
        )
        expect(host.runtimes).to eq(
          [ { "name" => "codex", "present" => true, "version" => "codex-cli 1.2.3", "required" => true } ]
        )
        expect(host.active_runs).to eq([ active_run.except(:token).deep_stringify_keys ])
        expect(host.runtimes.to_json).not_to include("secret", "private")
        expect(host.active_runs.to_json).not_to include("must-not-be-saved")
      end
    end

    it "usa intervallo e grace del payload per la scadenza host senza cambiare il contratto monitor" do
      post "/api/v1/projects/#{project.id}/crons/automator-tick/check_in", headers:,
           params: telemetry.merge(expected_interval_minutes: 2, grace_minutes: 1), as: :json

      expect(response).to have_http_status(:accepted)
      expect(host.reload).to have_attributes(
        heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1
      )
      expect(project.cron_monitors.sole).to have_attributes(expected_interval_minutes: 2, grace_minutes: 1)
    end

    it "deriva la cadenza host dal monitor esistente quando il payload la omette" do
      Crons::RecordCheckIn.call(
        project:, slug: "automator-tick", expected_interval_minutes: 10_081, grace_minutes: 10_081
      )

      post "/api/v1/projects/#{project.id}/crons/automator-tick/check_in", headers:,
           params: telemetry, as: :json

      expect(response).to have_http_status(:accepted)
      expect(host.reload).to have_attributes(
        heartbeat_expected_interval_minutes: 10_081, heartbeat_grace_minutes: 10_081
      )
    end

    it "payload host invalido → 422 e nessuna scrittura parziale" do
      expect do
        post "/api/v1/projects/#{project.id}/crons/automator-tick/check_in", headers:,
             params: telemetry.merge(host_status: "root", slots: 0), as: :json
      end.not_to change(project.cron_monitors, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-AGENT-004")
      expect(host.reload.last_heartbeat_at).to be_nil
    end

    it "fa rollback della telemetria se il check-in cron fallisce" do
      cron_error = AppError.new(
        "Monitor non valido", code: "R422-CRON-001", status: :unprocessable_content
      )
      allow(Crons::RecordCheckIn).to receive(:call).and_return(Result.err(cron_error))

      post "/api/v1/projects/#{project.id}/crons/automator-tick/check_in", headers:,
           params: telemetry, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-CRON-001")
      expect(host.reload).to have_attributes(last_heartbeat_at: nil, heartbeat_project_id: nil)
    end

    it "host di un'altra organizzazione → 404 senza rivelarne l'esistenza (anti-BOLA)" do
      foreign_host = create(:agent_host)

      post "/api/v1/projects/#{project.id}/crons/automator-tick/check_in", headers:,
           params: telemetry.merge(host_id: foreign_host.id), as: :json

      expect(response).to have_http_status(:not_found)
      expect(foreign_host.reload.last_heartbeat_at).to be_nil
      expect(project.cron_monitors).to be_empty
    end

    it "un token ingest di un altro progetto della stessa org non può impersonare l'host già legato" do
      post "/api/v1/projects/#{project.id}/crons/automator-tick/check_in", headers:, params: telemetry, as: :json
      expect(response).to have_http_status(:accepted)

      other_environment = create(:environment, organization:).tap { |value| mapped_project.environments << value }
      other_token = Projects::Tokens::Issue.call(
        project: mapped_project, name: "Other ingest", host: "bugs.example.com",
        environment: other_environment
      ).value.fetch(:secret)

      expect do
        post "/api/v1/projects/#{mapped_project.id}/crons/automator-tick/check_in",
             headers: { "Authorization" => "Bearer #{other_token}" },
             params: telemetry.merge(host_status: "waiting"), as: :json
      end.not_to(change { host.reload.host_status })

      expect(response).to have_http_status(:not_found)
      expect(host.reload.heartbeat_project).to eq(project)
    end

    it "host revocato → 404 e non aggiorna lo snapshot" do
      host.update!(revoked_at: 1.minute.ago)

      post "/api/v1/projects/#{project.id}/crons/automator-tick/check_in", headers:, params: telemetry, as: :json

      expect(response).to have_http_status(:not_found)
      expect(host.reload.last_heartbeat_at).to be_nil
    end

    it "repository non appartenente all'organizzazione → 422 con una sola validazione batch" do
      foreign_project = create(:project, key: "OTHR")

      queries = captured_sql do
        post "/api/v1/projects/#{project.id}/crons/automator-tick/check_in", headers:,
             params: telemetry.merge(repositories: [ foreign_project.key ]), as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(queries.grep(/SELECT "projects"\."key" FROM/i).size).to eq(1)
      expect(host.reload.last_heartbeat_at).to be_nil
    end
  end
end
