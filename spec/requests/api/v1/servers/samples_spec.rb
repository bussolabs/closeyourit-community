# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Servers::Samples (ingest agent)", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:secret) do
    Servers::EnrollmentTokens::Issue.call(organization:, name: "fleet").value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}", "CONTENT_TYPE" => "application/json" } }
  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/servers/agent_payload.json").read) }

  describe "POST /api/v1/servers/samples" do
    it "bearer valido → 202, auto-registra l'host e accoda l'IngestJob" do
      expect do
        post "/api/v1/servers/samples", params: payload.to_json, headers: headers
      end.to have_enqueued_job(Servers::IngestJob).once
        .and change(Servers::Host, :count).by(1)

      expect(response).to have_http_status(:accepted)
      host = Servers::Host.last
      expect(host.organization).to eq(organization)
      expect(host.fingerprint).to eq(payload["fingerprint"])
      expect(host.name).to eq("apps-staging")
      expect(response.parsed_body.dig("data", "accepted")).to be(true)
      expect(response.parsed_body.dig("data", "host_id")).to eq(host.id)
      expect(response.parsed_body.dig("data", "host_token")).to be_nil
    end

    # CYRA-649 — la salute della flotta si misura su questo istante, scritto dal controller nel
    # momento in cui la richiesta entra. Prima esisteva solo last_seen_at, che scrive l'ingest
    # asincrono: bastava un arretrato nella corsia dei dati per far sembrare giù tutta la flotta.
    # Nessun job eseguito qui di proposito: è esattamente lo scenario del guasto.
    it "registra l'ora di arrivo del push anche se i job non girano" do
      host = create(:server_host, organization:, fingerprint: payload["fingerprint"],
                    status: :up, last_push_at: 1.hour.ago, last_seen_at: 1.hour.ago)

      freeze_time do
        post "/api/v1/servers/samples", params: payload.to_json, headers: headers

        expect(response).to have_http_status(:accepted)
        expect(host.reload.last_push_at).to eq(Time.current)
      end
      # L'età della fotografia resta quella dell'ingest: i due istanti non si confondono.
      expect(host.last_seen_at).to be_within(1.second).of(1.hour.ago)
    end

    it "registra l'arrivo anche quando l'agent manda una fotografia vecchia" do
      host = create(:server_host, organization:, fingerprint: payload["fingerprint"], status: :up)
      stale_payload = payload.merge("recorded_at" => 2.hours.ago.iso8601)

      freeze_time do
        post "/api/v1/servers/samples", params: stale_payload.to_json, headers: headers

        expect(host.reload.last_push_at).to eq(Time.current)
      end
    end

    it "l'host revocato riceve 403 e non aggiorna l'ora di arrivo" do
      host = create(:server_host, :revoked, organization:, fingerprint: payload["fingerprint"],
                    last_push_at: 1.hour.ago)

      expect do
        post "/api/v1/servers/samples", params: payload.to_json, headers: headers
      end.not_to change { host.reload.last_push_at }

      expect(response).to have_http_status(:forbidden)
    end

    # CYRA-469 — al primo enrollment l'host resta legato al codice con cui si è presentato.
    it "lega l'host auto-registrato al codice di enrollment" do
      post "/api/v1/servers/samples", params: payload.to_json, headers: headers

      expect(response).to have_http_status(:accepted)
      token = Servers::EnrollmentToken.find_by!(organization: organization)
      expect(Servers::Host.last.enrollment_token).to eq(token)
    end

    it "push successivo con lo stesso fingerprint riusa l'host (nessun duplicato)" do
      create(:server_host, organization: organization, fingerprint: payload["fingerprint"], name: "già-noto")

      expect do
        post "/api/v1/servers/samples", params: payload.to_json, headers: headers
      end.not_to change(Servers::Host, :count)

      expect(response).to have_http_status(:accepted)
    end

    it "agent >= 0.4 riceve una credenziale host al primo arruolamento" do
      host = create(:server_host, organization:, fingerprint: payload["fingerprint"])
      upgraded = payload.merge("agent_version" => "0.4.0")

      post "/api/v1/servers/samples", params: upgraded.to_json, headers: headers

      expect(response.parsed_body.dig("data", "host_token")).to start_with("cyi_h_")
      expect(host.host_tokens.active.count).to eq(1)
    end

    it "accetta la credenziale per-host e rifiuta un fingerprint diverso" do
      host = create(:server_host, organization:, fingerprint: payload["fingerprint"])
      host_secret = "cyi_h_host-secret"
      create(:server_host_token, host:, token_digest: Digest::SHA256.hexdigest(host_secret))
      host_headers = headers.merge("Authorization" => "Bearer #{host_secret}")

      post "/api/v1/servers/samples", params: payload.to_json, headers: host_headers
      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("data", "host_token")).to be_nil

      post "/api/v1/servers/samples", params: payload.merge("fingerprint" => "altro").to_json,
           headers: host_headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-SERVER-003")
    end

    # CYRA-245 — il codice della flotta è lo stesso su ogni macchina e sta in chiaro su ognuna;
    # l'impronta di una macchina si legge dal pannello. Chi ha entrambi si presentava al posto di
    # quella macchina: la sua credenziale veniva revocata e la sonda vera restava muta per sempre.
    describe "tentativo di prendere il posto di una macchina già collegata (CYRA-245)" do
      let(:upgraded) { payload.merge("agent_version" => "0.4.0") }
      let!(:host) { create(:server_host, organization:, fingerprint: payload["fingerprint"]) }
      let!(:live_token) { create(:server_host_token, host:, last_used_at: 30.seconds.ago) }

      it "non revoca la credenziale viva, non ne emette una nuova e registra il tentativo" do
        expect do
          post "/api/v1/servers/samples", params: upgraded.to_json, headers: headers
        end.not_to change { host.host_tokens.active.count }

        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body.dig("data", "host_token")).to be_nil
        expect(live_token.reload.revoked_at).to be_nil
        expect(host.reload.enrollment_conflict_at).to be_present
      end

      # Il push resta accettato: rifiutarlo trasformerebbe una reinstallazione in un buco nei dati,
      # e non è la credenziale che l'ingest protegge (l'impronta è pubblica per costruzione).
      it "accetta comunque i dati del push" do
        expect do
          post "/api/v1/servers/samples", params: upgraded.to_json, headers: headers
        end.to have_enqueued_job(Servers::IngestJob).once
      end

      it "dentro la finestra di riadozione la nuova sonda prende il posto e la vecchia credenziale cade" do
        host.update!(reenrollment_requested_at: Time.current)

        post "/api/v1/servers/samples", params: upgraded.to_json, headers: headers

        expect(response.parsed_body.dig("data", "host_token")).to start_with("cyi_h_")
        expect(live_token.reload.revoked_at).to be_present
        expect(host.host_tokens.active.count).to eq(1)
        # La finestra si chiude appena è servita: un secondo agent non prende il posto del primo.
        expect(host.reload.reenrollment_requested_at).to be_nil
      end

      it "finestra di riadozione scaduta → vale come se non fosse mai stata aperta" do
        host.update!(
          reenrollment_requested_at: (Servers::Constants::REENROLLMENT_WINDOW_SECONDS + 60).seconds.ago
        )

        post "/api/v1/servers/samples", params: upgraded.to_json, headers: headers

        expect(response.parsed_body.dig("data", "host_token")).to be_nil
        expect(live_token.reload.revoked_at).to be_nil
      end
    end

    # CYRA-245 — Scenario 2: la sonda esclusa deve poter tornare, non restare muta. Il 401 generico
    # non distingue «codice sbagliato» da «la tua credenziale non vale più»: con un codice suo la
    # sonda sa che deve ripresentarsi con il codice della flotta.
    it "credenziale per-host revocata → 401 R401-SERVER-002" do
      host = create(:server_host, organization:, fingerprint: payload["fingerprint"])
      host_secret = "cyi_h_host-secret"
      create(:server_host_token, host:, token_digest: Digest::SHA256.hexdigest(host_secret),
             revoked_at: Time.current)

      post "/api/v1/servers/samples", params: payload.to_json,
           headers: headers.merge("Authorization" => "Bearer #{host_secret}")

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("R401-SERVER-002")
    end

    it "senza bearer → 401 R401-SERVER-001" do
      post "/api/v1/servers/samples", params: payload.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("R401-SERVER-001")
    end

    it "con token revocato → 401 R401-SERVER-001" do
      secret # forza l'emissione del token (let lazy) prima di revocarlo
      Servers::EnrollmentTokens::Revoke.call(token: Servers::EnrollmentToken.find_by!(organization: organization))

      post "/api/v1/servers/samples", params: payload.to_json, headers: headers

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("R401-SERVER-001")
    end

    it "con host revocato → 403 R403-SERVER-002 e nessun job" do
      create(:server_host, :revoked, organization: organization, fingerprint: payload["fingerprint"])

      expect do
        post "/api/v1/servers/samples", params: payload.to_json, headers: headers
      end.not_to have_enqueued_job(Servers::IngestJob)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-SERVER-002")
    end

    it "senza fingerprint → 422 R422-SERVER-001" do
      post "/api/v1/servers/samples", params: payload.except("fingerprint").to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-SERVER-001")
    end

    it "payload oltre il limite → 413 R413-SERVER-002" do
      stub_const("Servers::Constants::MAX_PAYLOAD_BYTES", 10)

      post "/api/v1/servers/samples", params: payload.to_json, headers: headers

      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-SERVER-002")
    end

    it "body non parsabile → 422 R422-SERVER-004" do
      post "/api/v1/servers/samples", params: "{né json", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-SERVER-004")
    end

    it "body JSON non-oggetto (array) → 422 R422-SERVER-004" do
      post "/api/v1/servers/samples", params: "[1,2]", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-SERVER-004")
    end

    it "body gzip (Content-Encoding dell'agent) → 202 col payload decompresso" do
      gzipped = ActiveSupport::Gzip.compress(payload.to_json)

      expect do
        post "/api/v1/servers/samples", params: gzipped,
             headers: headers.merge("CONTENT_TYPE" => "application/json", "CONTENT_ENCODING" => "gzip")
      end.to have_enqueued_job(Servers::IngestJob)
        .with(hash_including(payload: hash_including("fingerprint" => payload["fingerprint"])))

      expect(response).to have_http_status(:accepted)
      expect(Servers::Host.last.hostname).to eq("apps-staging")
    end

    it "gzip-bomb (decompresso oltre il limite) → 413 R413-SERVER-002" do
      bomb = ActiveSupport::Gzip.compress("x" * (Servers::Constants::MAX_PAYLOAD_BYTES + 1))

      post "/api/v1/servers/samples", params: bomb, headers: headers

      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-SERVER-002")
    end

    it "gzip corrotto → 422 R422-SERVER-004" do
      post "/api/v1/servers/samples", params: "\x1f\x8bnon-gzip".b, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-SERVER-004")
    end

    it "il blocco journal persiste entries e snapshot end-to-end (HTTP → job → righe)" do
      perform_enqueued_jobs do
        post "/api/v1/servers/samples", params: payload.to_json, headers: headers
      end

      expect(response).to have_http_status(:accepted)
      host = Servers::Host.last
      expect(host.journal_entries.count).to eq(2)
      expect(host.journal_snapshots).to have_key("backup.service")
    end

    it "il blocco database persiste snapshot e hot columns end-to-end (HTTP → job → righe)" do
      perform_enqueued_jobs do
        post "/api/v1/servers/samples", params: payload.to_json, headers: headers
      end

      expect(response).to have_http_status(:accepted)
      host = Servers::Host.last
      expect(host.db_role).to eq("primary")
      expect(host.database_snapshot.dig("connections", "total")).to eq(42)
      sample = Servers::Sample.last
      expect(sample.db_up).to be(true)
      expect(sample.db_connections).to eq(42)
      expect(sample.db_replication_lag_seconds).to eq(0.12)
    end

    it "payload SENZA blocco database (host non-DB, agent vecchio) → 202 e nulla di database" do
      perform_enqueued_jobs do
        post "/api/v1/servers/samples", params: payload.except("database").to_json, headers: headers
      end

      expect(response).to have_http_status(:accepted)
      host = Servers::Host.last
      expect(host.database_snapshot).to eq({})
      expect(host.db_role).to be_nil
      sample = Servers::Sample.last
      expect(sample.db_up).to be_nil
      expect(sample.db_connections).to be_nil
      expect(sample.payload).not_to have_key("database")
      # il resto del campione resta invariato
      expect(sample.cpu_pct).to eq(12.34)
      expect(host.hostname).to eq("apps-staging")
    end

    it "aggiorna last_used_at del token stantio (debounce)" do
      token = Servers::EnrollmentToken.find_by!(token_digest: Digest::SHA256.hexdigest(secret))
      token.update_column(:last_used_at, 10.minutes.ago)

      post "/api/v1/servers/samples", params: payload.to_json, headers: headers

      expect(token.reload.last_used_at).to be > 1.minute.ago
    end
  end
end
