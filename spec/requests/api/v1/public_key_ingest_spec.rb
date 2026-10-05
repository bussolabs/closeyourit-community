# frozen_string_literal: true

require "rails_helper"

# CYRA-108: gli SDK browser (closeyourit-js) non hanno un segreto — usano la DSN public key non
# segreta. Prima solo errori/messaggi (route Sentry /api/:project_id/{envelope,store}) accettavano la
# public key; log/metriche/visite/replay la rifiutavano e serviva un bearer o un gateway applicativo.
# Ora TUTTI i canali di sola scrittura dell'API v1 accettano la public key, con enforce di progetto e
# scope ingest, e la public key NON apre alcuna API di lettura.
RSpec.describe "Api::V1 ingest con DSN public key (browser)", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) do
    create(:project, organization:, analytics_enabled: true, session_replay_enabled: true)
  end
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:issued) do
    Projects::Tokens::Issue.call(
      project:, name: "Browser", host: "bugs.example.com", environment:
    ).value
  end
  let(:public_key) { issued[:token].public_key }
  let(:json) { { "CONTENT_TYPE" => "application/json" } }

  # La public key viaggia come query param (browser-friendly: nessun header CORS extra) oppure come
  # header X-Sentry-Auth (parità con il drop-in Sentry). Entrambe le forme vengono accettate.
  def with_key(path) = "#{path}?sentry_key=#{public_key}"

  def dsn_header
    { "X-Sentry-Auth" => "Sentry sentry_key=#{public_key}, sentry_version=7", "CONTENT_TYPE" => "application/json" }
  end

  # CYRA-716 — la scadenza vale anche per la DSN public key: gli SDK browser che la portano vengono
  # rifiutati appena la data passa, come il bearer.
  describe "scadenza del token (CYRA-716)" do
    let(:a_termine) do
      Projects::Tokens::Issue.call(
        project:, name: "Browser a termine", host: "bugs.example.com", environment:,
        expires_at: 2.days.from_now
      ).value[:token].public_key
    end

    it "dopo la scadenza l'ingest via DSN è rifiutato con 401 R401-AUTH-001" do
      key = a_termine
      travel 3.days do
        post "/api/v1/projects/#{project.id}/events?sentry_key=#{key}",
             params: { "event_id" => "feedface", "level" => "error", "message" => "browser" }.to_json,
             headers: json

        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["X-CloseYourIt-Ingest-Authorized"]).to be_nil
        expect(response.parsed_body.dig("error", "code")).to eq("R401-AUTH-001")
      end
    end
  end

  describe "ogni canale di sola scrittura accetta la public key" do
    it "events → 202 e accoda Errors::IngestJob" do
      expect do
        post with_key("/api/v1/projects/#{project.id}/events"),
             params: { "event_id" => "feedface", "level" => "error", "message" => "browser" }.to_json,
             headers: json
      end.to have_enqueued_job(Errors::IngestJob)
      expect(response).to have_http_status(:accepted)
      expect(response.headers["X-CloseYourIt-Ingest-Authorized"]).to eq("true")
    end

    it "logs → 202 e accoda Logs::IngestJob" do
      expect do
        post with_key("/api/v1/projects/#{project.id}/logs"),
             params: { "event_id" => SecureRandom.uuid, "level" => "info", "message" => "hi" }.to_json,
             headers: json
      end.to have_enqueued_job(Logs::IngestJob)
      expect(response).to have_http_status(:accepted)
    end

    it "metrics → 202 e accoda Metrics::IngestJob" do
      expect do
        post with_key("/api/v1/projects/#{project.id}/metrics"),
             params: { "kind" => "slow_query", "label" => "SELECT 1", "duration_ms" => 12 }.to_json,
             headers: json
      end.to have_enqueued_job(Metrics::IngestJob)
      expect(response).to have_http_status(:accepted)
    end

    it "pageviews (public key via header X-Sentry-Auth) → 202 e accoda Analytics::IngestJob" do
      expect do
        post "/api/v1/projects/#{project.id}/pageviews",
             params: { "event_id" => SecureRandom.uuid, "hostname" => "www.example.test",
                       "path" => "/x", "occurred_at" => Time.current.iso8601 }.to_json,
             headers: dsn_header.merge("HTTP_USER_AGENT" => "Mozilla/5.0 Chrome/126.0.0.0", "REMOTE_ADDR" => "203.0.113.9")
      end.to have_enqueued_job(Analytics::IngestJob)
      expect(response).to have_http_status(:accepted)
    end

    it "replays → 202 e accoda Replays::IngestJob" do
      expect do
        post with_key("/api/v1/projects/#{project.id}/replays"),
             params: { "replay_session_id" => SecureRandom.uuid,
                       "events" => [ { "type" => 2, "timestamp" => 1 } ] }.to_json,
             headers: json
      end.to have_enqueued_job(Replays::IngestJob)
      expect(response).to have_http_status(:accepted)
    end
  end

  describe "la public key NON espone alcuna API di lettura (Definition of Done)" do
    it "GET error_groups con public key → 401 (le read sono solo bearer)" do
      get with_key("/api/v1/error_groups")
      expect(response).to have_http_status(:unauthorized)
    end

    it "GET metric_groups con public key → 401" do
      get with_key("/api/v1/metric_groups")
      expect(response).to have_http_status(:unauthorized)
    end

    it "GET log_entries con public key → 401" do
      get with_key("/api/v1/log_entries")
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "enforce progetto e scope, credenziale non valida" do
    def log_body = { "event_id" => SecureRandom.uuid, "level" => "info", "message" => "x" }.to_json

    it "public key valida ma project_id del path di un altro progetto → 404 (anti-BOLA)" do
      other = create(:project, organization:)
      post with_key("/api/v1/projects/#{other.id}/logs"), params: log_body, headers: json
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-LOG-001")
    end

    it "public key sconosciuta → 401" do
      post "/api/v1/projects/#{project.id}/logs?sentry_key=deadbeef", params: log_body, headers: json
      expect(response).to have_http_status(:unauthorized)
    end

    it "public key di un token read-only → 403 (niente ingest senza scope ingest)" do
      read_only = Projects::Tokens::Issue.call(
        project:, name: "Read", host: "bugs.example.com", environment:, scopes: [ "read" ]
      ).value[:token]
      post "/api/v1/projects/#{project.id}/logs?sentry_key=#{read_only.public_key}", params: log_body, headers: json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-AUTH-002")
    end

    it "public key di un token revocato → 401" do
      issued[:token].update!(revoked_at: Time.current)
      post with_key("/api/v1/projects/#{project.id}/logs"), params: log_body, headers: json
      expect(response).to have_http_status(:unauthorized)
    end

    it "il bearer segreto continua a funzionare sugli stessi endpoint" do
      post "/api/v1/projects/#{project.id}/logs", params: log_body,
           headers: json.merge("Authorization" => "Bearer #{issued[:secret]}")
      expect(response).to have_http_status(:accepted)
    end
  end
end
