# frozen_string_literal: true

require "rails_helper"

# CORS sugli endpoint di ingest: gli SDK browser (closeyourit-js) postano da origini arbitrarie
# (i siti dei progetti monitorati) verso /api/v1/projects/:id/{events,metrics,logs,pageviews,replays}.
# Verifichiamo il preflight OPTIONS e la richiesta reale sugli endpoint di ingest, che l'header
# X-Sentry-Auth (public key, CYRA-108) sia consentito, e che il resto dell'app (rotte
# web/member/health) NON esponga alcun header CORS.
RSpec.describe "Api::V1 ingest CORS", type: :request do
  include ActiveJob::TestHelper

  let(:origin) { "https://sito-cliente.example" }

  def preflight_headers
    {
      "HTTP_ORIGIN" => origin,
      "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST",
      "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "Authorization, Content-Type"
    }
  end

  describe "preflight OPTIONS sugli endpoint di ingest" do
    # Il preflight è intercettato da Rack::Cors prima del routing: non richiede né progetto
    # reale né token (il browser non invia Authorization nel preflight), basta un UUID nel path.
    let(:project_id) { SecureRandom.uuid }

    %w[events metrics logs pageviews replays].each do |resource|
      it "risponde 2xx con header CORS permissivi su /#{resource}" do
        process :options, "/api/v1/projects/#{project_id}/#{resource}", headers: preflight_headers

        expect(response).to have_http_status(:success)
        expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
        expect(response.headers["Access-Control-Allow-Methods"]).to match(/POST/i)
        expect(response.headers["Access-Control-Allow-Headers"]).to match(/Authorization/i)
      end
    end

    it "consente l'header X-Sentry-Auth nel preflight (public key dal browser, CYRA-108)" do
      process :options, "/api/v1/projects/#{project_id}/logs",
              headers: preflight_headers.merge("HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "X-Sentry-Auth")

      expect(response).to have_http_status(:success)
      expect(response.headers["Access-Control-Allow-Headers"]).to match(/X-Sentry-Auth/i)
    end
  end

  describe "richiesta reale cross-origin (POST con Origin)" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
    let(:secret) do
      Projects::Tokens::Issue.call(
        project:, name: "CI", host: "bugs.example.com", environment:
      ).value[:secret]
    end
    let(:headers) do
      { "Authorization" => "Bearer #{secret}", "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => origin }
    end

    def event = { "event_id" => "feedface", "level" => "error", "message" => "ci signal" }

    it "POST /events → 202 con Access-Control-Allow-Origin: *" do
      post "/api/v1/projects/#{project.id}/events", params: event.to_json, headers: headers

      expect(response).to have_http_status(:accepted)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
    end
  end

  describe "endpoint NON-ingest (nessun CORS)" do
    it "GET /up con Origin → nessun header Access-Control-Allow-Origin" do
      get "/up", headers: { "HTTP_ORIGIN" => origin }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
    end
  end
end
