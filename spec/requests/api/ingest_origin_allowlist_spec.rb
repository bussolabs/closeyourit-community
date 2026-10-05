# frozen_string_literal: true

require "rails_helper"

# CYRA-109 — Origin allowlist del public ingest. La DSN public key non è segreta (viaggia negli SDK
# browser): può essere copiata e usata fuori dal sito legittimo. Un progetto può dichiarare le origini
# ammesse; il gateway ingest rifiuta le richieste BROWSER (con header Origin) da origini non elencate,
# con un errore chiaro. È una difesa AGGIUNTIVA, mai un'autenticazione: la lista vuota non vincola, e
# le richieste SENZA Origin (client non-browser: SDK server, CI) non vengono mai bloccate.
RSpec.describe "Public ingest — origin allowlist (CYRA-109)", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:issued) do
    Projects::Tokens::Issue.call(
      project:, name: "Browser", host: "bugs.example.com", environment:
    ).value
  end
  let(:public_key) { issued[:token].public_key }
  let(:secret) { issued[:secret] }
  let(:json) { { "CONTENT_TYPE" => "application/json" } }

  def event_body = { "event_id" => "feedface", "level" => "error", "message" => "browser" }.to_json

  # Ingest via DSN public key (canale v1 events), con o senza header Origin.
  def post_public_key(origin: :none)
    headers = json.dup
    headers["HTTP_ORIGIN"] = origin unless origin == :none
    post "/api/v1/projects/#{project.id}/events?sentry_key=#{public_key}", params: event_body, headers: headers
  end

  # Ingest via bearer secret server-side, con o senza header Origin.
  def post_bearer(origin: :none)
    headers = json.merge("Authorization" => "Bearer #{secret}")
    headers["HTTP_ORIGIN"] = origin unless origin == :none
    post "/api/v1/projects/#{project.id}/events", params: event_body, headers: headers
  end

  context "0 origini (allowlist non configurata)" do
    it "accetta l'ingest con un Origin qualsiasi (nessun vincolo)" do
      post_public_key(origin: "https://qualsiasi.example")
      expect(response).to have_http_status(:accepted)
    end

    it "accetta l'ingest senza Origin" do
      post_public_key
      expect(response).to have_http_status(:accepted)
    end
  end

  context "1 origine consentita" do
    before { project.update!(allowed_origins: [ "https://app.example" ]) }

    it "accetta l'origine elencata" do
      post_public_key(origin: "https://app.example")
      expect(response).to have_http_status(:accepted)
    end

    it "rifiuta un'origine non elencata con 403 e un errore chiaro" do
      post_public_key(origin: "https://evil.example")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-INGEST-002")
    end

    it "NON blocca una richiesta senza Origin (client non-browser, es. SDK server)" do
      post_public_key
      expect(response).to have_http_status(:accepted)
    end

    it "NON blocca il bearer server-side senza Origin anche con allowlist attiva" do
      post_bearer
      expect(response).to have_http_status(:accepted)
    end

    it "applica il controllo anche al bearer quando la richiesta porta un Origin vietato" do
      post_bearer(origin: "https://evil.example")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-INGEST-002")
    end
  end

  context "N origini consentite" do
    before { project.update!(allowed_origins: %w[https://a.example https://b.example]) }

    it "accetta ciascuna origine elencata" do
      post_public_key(origin: "https://b.example")
      expect(response).to have_http_status(:accepted)
    end

    it "rifiuta un'origine fuori lista con 403" do
      post_public_key(origin: "https://c.example")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-INGEST-002")
    end
  end

  # Il secondo gateway public ingest: route Sentry drop-in /api/:project_id/store (public key).
  context "route Sentry drop-in /api/:project_id/store" do
    before { project.update!(allowed_origins: [ "https://app.example" ]) }

    def post_store(origin:)
      headers = json.dup
      headers["HTTP_ORIGIN"] = origin
      post "/api/#{project.id}/store?sentry_key=#{public_key}", params: event_body, headers: headers
    end

    it "accetta l'origine elencata" do
      post_store(origin: "https://app.example")
      expect(response).to have_http_status(:ok)
    end

    it "rifiuta un'origine non elencata con 403 R403-INGEST-002" do
      post_store(origin: "https://evil.example")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-INGEST-002")
    end
  end
end
