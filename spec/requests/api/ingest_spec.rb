# frozen_string_literal: true

require "rails_helper"
require "stringio"
require "zlib"

RSpec.describe "Api::Ingest (Sentry-compatibile)", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:token) do
    Projects::Tokens::Issue.call(
      project:, name: "SDK", host: "bugs.example.com", environment:
    ).value[:token]
  end
  let(:public_key) { token.public_key }

  def event(event_id: "abc123def456")
    { "event_id" => event_id, "level" => "error",
      "exception" => { "values" => [ {
        "type" => "RuntimeError", "value" => "boom",
        "stacktrace" => { "frames" => [ { "module" => "App", "function" => "call", "in_app" => true } ] }
      } ] } }
  end

  def envelope(evt = event)
    ([ { "event_id" => evt["event_id"] }, { "type" => "event" }, evt ].map(&:to_json).join("\n")) + "\n"
  end

  def auth_header(key = public_key)
    { "X-Sentry-Auth" => "Sentry sentry_key=#{key}, sentry_version=7", "CONTENT_TYPE" => "application/x-sentry-envelope" }
  end

  # CYRA-251 — le rotte Sentry envelope/store portano `format: false`: gli SDK Sentry non mandano mai
  # un'estensione, e senza il flag `/api/:id/envelope.json` instradava (format json), aprendo una forma
  # extra dell'indirizzo su cui il rate limit per-progetto non scattava.
  describe "routing envelope/store (format: false)" do
    it "instrada la forma canonica senza estensione" do
      expect(Rails.application.routes.recognize_path("/api/abc/envelope", method: :post))
        .to include(controller: "api/ingest", action: "envelope")
      expect(Rails.application.routes.recognize_path("/api/abc/store", method: :post))
        .to include(controller: "api/ingest", action: "store")
    end

    it "NON instrada la forma con estensione di formato" do
      expect { Rails.application.routes.recognize_path("/api/abc/envelope.json", method: :post) }
        .to raise_error(ActionController::RoutingError)
      expect { Rails.application.routes.recognize_path("/api/abc/store.JSON", method: :post) }
        .to raise_error(ActionController::RoutingError)
    end
  end

  describe "POST /api/:project_id/envelope" do
    it "DSN valida via header → 200 { id } e accoda l'IngestJob" do
      expect do
        post "/api/#{project.id}/envelope", params: envelope, headers: auth_header
      end.to have_enqueued_job(Errors::IngestJob)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["id"]).to eq("abc123def456")
    end

    it "DSN valida via query ?sentry_key= → 200" do
      post "/api/#{project.id}/envelope?sentry_key=#{public_key}", params: envelope, headers: { "CONTENT_TYPE" => "application/x-sentry-envelope" }
      expect(response).to have_http_status(:ok)
    end

    it "end-to-end: eseguendo il job nasce il gruppo + evento" do
    # except: l'embed del gruppo esce verso un servizio che qui non è configurato e dal CYRA-713 un
    # job che fallisce non viene più ritentato in silenzio: qui si prova l'ingest, non l'embedding.
    perform_enqueued_jobs(except: Errors::EmbedGroupJob) do
        post "/api/#{project.id}/envelope", params: envelope, headers: auth_header
      end
      expect(project.error_groups.count).to eq(1)
      expect(project.error_groups.sole.title).to eq("RuntimeError: boom")
      expect(project.error_events.count).to eq(1)
    end

    it "envelope gzip → 200" do
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io); gz.write(envelope); gz.close
      post "/api/#{project.id}/envelope", params: io.string,
           headers: auth_header.merge("CONTENT_TYPE" => "application/x-sentry-envelope")
      expect(response).to have_http_status(:ok)
    end

    it "sentry_key sconosciuta → 401 R401-AUTH-001" do
      post "/api/#{project.id}/envelope", params: envelope, headers: auth_header("deadbeef")
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("R401-AUTH-001")
    end

    it "BOLA: DSN di un progetto usata sul path di un altro progetto → 401" do
      other = create(:project, organization:)
      post "/api/#{other.id}/envelope", params: envelope, headers: auth_header
      expect(response).to have_http_status(:unauthorized)
    end

    it "token revocato → 401" do
      Projects::Tokens::Revoke.call(token:)
      post "/api/#{project.id}/envelope", params: envelope, headers: auth_header
      expect(response).to have_http_status(:unauthorized)
    end

    it "payload troppo grande → 413 R413-INGEST-001" do
      big = "x" * (1.megabyte + 1)
      post "/api/#{project.id}/envelope", params: big, headers: auth_header
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-INGEST-001")
    end

    it "envelope malformata → 422 R422-INGEST-001" do
      post "/api/#{project.id}/envelope", params: "{bad\n{}\n", headers: auth_header
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-INGEST-001")
    end
  end

  describe "POST /api/:project_id/store (legacy)" do
    it "singolo evento JSON → 200 { id } + enqueue" do
      expect do
        post "/api/#{project.id}/store", params: event.to_json, headers: auth_header
      end.to have_enqueued_job(Errors::IngestJob)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["id"]).to eq("abc123def456")
    end

    it "evento gzip → 200" do
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io); gz.write(event.to_json); gz.close
      post "/api/#{project.id}/store", params: io.string, headers: auth_header
      expect(response).to have_http_status(:ok)
    end

    it "body malformato → 422" do
      post "/api/#{project.id}/store", params: "{nope", headers: auth_header
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "body JSON valido ma non-oggetto (42, array) → 422 R422-INGEST-001, non 500 da TypeError" do
      post "/api/#{project.id}/store", params: "42", headers: auth_header
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-INGEST-001")

      post "/api/#{project.id}/store", params: '[{"event_id":"x"}]', headers: auth_header
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "payload oltre 1MB → 413 (stessi limiti dell'envelope)" do
      big = { "event_id" => "x" * 1.megabyte }.to_json
      post "/api/#{project.id}/store", params: big, headers: auth_header
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig("error", "code")).to eq("R413-INGEST-001")
    end

    it "gzip-bomb (decompresso oltre 5MB) → 413" do
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io); gz.write(%({"pad":"#{'a' * 6.megabytes}"})); gz.close
      post "/api/#{project.id}/store", params: io.string, headers: auth_header
      expect(response).to have_http_status(:content_too_large)
    end
  end

  # CYRA-211 — Il corpo dell'evento non viaggia più negli argomenti del job: in coda va solo l'id della
  # riga di staging, il payload resta in Errors::IngestPayload finché il worker non lo persiste.
  describe "il corpo dell'evento resta fuori dalla coda (CYRA-211)" do
    it "Scenario 1: in coda viaggia solo un riferimento, non il contenuto" do
      post "/api/#{project.id}/store", params: event.to_json, headers: auth_header

      expect(enqueued_jobs.size).to eq(1)
      expect(enqueued_jobs.first.to_json).not_to include("boom")
      staged = Errors::IngestPayload.sole
      expect(staged.payload.dig("exception", "values", 0, "value")).to eq("boom")
    end

    it "Scenario 2: un corpo grande non gonfia gli argomenti del job (il freno protegge il trasporto)" do
      big = event.merge("blob" => "x" * 40_000)
      post "/api/#{project.id}/store", params: big.to_json, headers: auth_header

      expect(enqueued_jobs.size).to eq(1)
      expect(enqueued_jobs.first.to_json).not_to include("x" * 40_000)
      expect(Errors::IngestPayload.sole.payload["blob"]).to eq("x" * 40_000)
    end
  end

  # Envelope REALE serializzata da sentry-ruby 6.6.2 (fixture generata via transport della gem,
  # non a mano): header con dsn/sdk/sent_at/trace + item event con stacktrace/breadcrumbs/user/tags.
  # È il contratto wire vero degli SDK ufficiali: URL con trailing slash, X-Sentry-Auth completo.
  describe "compatibilità wire con sentry-ruby reale" do
    let(:real_envelope) do
      lines = Rails.root.join("spec/fixtures/sentry/envelope_event.ndjson").read.lines
      header = JSON.parse(lines.first).merge("dsn" => token.to_dsn(host: "bugs.example.com"))
      [ header.to_json + "\n", *lines.drop(1) ].join
    end
    let(:real_event) { JSON.parse(real_envelope.lines[2]) }
    let(:sentry_auth_header) do
      {
        "X-Sentry-Auth" => "Sentry sentry_version=7, sentry_timestamp=#{Time.current.to_i}, " \
                           "sentry_key=#{public_key}, sentry_client=sentry-ruby/6.6.2",
        "Content-Type" => "application/x-sentry-envelope",
        "Content-Encoding" => "",
        "User-Agent" => "sentry-ruby/6.6.2"
      }
    end

    it "POST su /envelope/ (trailing slash dell'SDK) → 200 {id} e gruppo con trace_id da contexts.trace" do
      perform_enqueued_jobs(except: Errors::EmbedGroupJob) do
        post "/api/#{project.id}/envelope/", params: real_envelope, headers: sentry_auth_header
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["id"]).to eq(real_event["event_id"])

      stored = Errors::Event.find_by!(event_id: real_event["event_id"])
      expect(stored.trace_id).to eq(real_event.dig("contexts", "trace", "trace_id"))
      expect(stored.group.title).to include("NoMethodError")
      # PII dell'utente scrubbata (la fixture porta user.email reale)
      expect(stored.payload.dig("user", "email")).to be_nil
    end

    it "la stessa envelope gzippata (Content-Encoding: gzip) → 200" do
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io); gz.write(real_envelope); gz.close

      post "/api/#{project.id}/envelope/", params: io.string,
           headers: sentry_auth_header.merge("Content-Encoding" => "gzip")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["id"]).to eq(real_event["event_id"])
    end

    it "envelope sessions-only (release health, formato del SessionFlusher) → 200 con id null" do
      sessions_envelope = [
        { event_id: SecureRandom.uuid.delete("-"), sent_at: Time.current.iso8601 }.to_json,
        { type: "sessions" }.to_json,
        { attrs: { release: "v9.9.9", environment: "production" },
          aggregates: [ { started: Time.current.beginning_of_minute.iso8601, exited: 3 } ] }.to_json
      ].join("\n")

      expect do
        post "/api/#{project.id}/envelope/", params: sessions_envelope, headers: sentry_auth_header
      end.not_to have_enqueued_job(Errors::IngestJob)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["id"]).to be_nil
    end
  end

  it "token usato di recente: last_used_at non riscritto (debounce, ramo non-stantio)" do
    post "/api/#{project.id}/envelope", params: envelope, headers: auth_header   # primo uso → set
    used_at = token.reload.last_used_at
    expect(used_at).to be_present
    post "/api/#{project.id}/envelope", params: envelope(event(event_id: "second")), headers: auth_header
    expect(token.reload.last_used_at).to eq(used_at)   # non stantio → nessuna riscrittura
  end
end
