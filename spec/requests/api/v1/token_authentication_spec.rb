# frozen_string_literal: true

require "rails_helper"

# Verifica che il guard anti-BOLA (project_id del path == progetto del token) sia CENTRALIZZATO nel
# concern TokenAuthentication: vale per ogni rotta token-bearer con :project_id ed è esente sulle
# rotte read senza :project_id (error_groups/metric_groups/log_entries, types lookup).
RSpec.describe "Api::V1 TokenAuthentication — scope di progetto centralizzato", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:other_project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(
      project:, name: "CI", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}", "CONTENT_TYPE" => "application/json" } }

  def body = { "event_id" => SecureRandom.uuid, "level" => "error", "message" => "x" }.to_json

  describe "rotte con :project_id (ingest) → guard applicato dal concern" do
    it "events: project_id del path ≠ progetto del token → 404" do
      post "/api/v1/projects/#{other_project.id}/events", params: body, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "metrics: project_id del path ≠ progetto del token → 404" do
      post "/api/v1/projects/#{other_project.id}/metrics", params: body, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "logs: project_id del path ≠ progetto del token → 404 con envelope R404-LOG-001" do
      post "/api/v1/projects/#{other_project.id}/logs", params: body, headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-LOG-001")
    end

    it "project_id combaciante → passa il guard (202)" do
      post "/api/v1/projects/#{project.id}/events", params: body, headers: headers
      expect(response).to have_http_status(:accepted)
    end
  end

  # CYRA-716 — Scenario 1: passata la data di scadenza, le applicazioni che usano quel token vengono
  # rifiutate. La difesa vive nella risoluzione del bearer (scope .active), quindi vale per OGNI rotta
  # token-bearer: qui si prova su un canale d'ingest e su uno di lettura.
  describe "scadenza del token (CYRA-716)" do
    let(:scadenza) { 2.days.from_now }
    let(:a_termine) do
      Projects::Tokens::Issue.call(
        project:, name: "CI a termine", host: "bugs.example.com", environment:,
        expires_at: scadenza
      ).value[:secret]
    end
    let(:headers_a_termine) do
      { "Authorization" => "Bearer #{a_termine}", "CONTENT_TYPE" => "application/json" }
    end

    it "prima della scadenza il token autentica (202)" do
      post "/api/v1/projects/#{project.id}/events", params: body, headers: headers_a_termine
      expect(response).to have_http_status(:accepted)
    end

    it "dopo la scadenza l'ingest è rifiutato con 401 R401-AUTH-001" do
      token = a_termine
      travel 3.days do
        post "/api/v1/projects/#{project.id}/events", params: body,
             headers: { "Authorization" => "Bearer #{token}", "CONTENT_TYPE" => "application/json" }

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body.dig("error", "code")).to eq("R401-AUTH-001")
      end
    end

    it "dopo la scadenza anche la lettura della telemetria è rifiutata con 401" do
      token = a_termine
      travel 3.days do
        get "/api/v1/error_groups", headers: { "Authorization" => "Bearer #{token}" }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "rotte read senza :project_id → esenti dal guard" do
    it "error_groups col token valido → 200 (non 404)" do
      get "/api/v1/error_groups", headers: { "Authorization" => "Bearer #{secret}" }
      expect(response).to have_http_status(:ok)
    end
  end

  # Enforce degli scope del token (CYRA-37 / decisions/2026-07-09-cyi-token-server-only):
  # la lettura della telemetria richiede lo scope 'read', l'ingest lo scope 'ingest'.
  describe "enforce dello scope del token (ingest vs read)" do
    let(:ingest_only) do
      Projects::Tokens::Issue.call(
        project:, name: "ingest", host: "bugs.example.com", environment:, scopes: [ "ingest" ]
      ).value[:secret]
    end
    let(:read_only) do
      Projects::Tokens::Issue.call(
        project:, name: "read", host: "bugs.example.com", environment:, scopes: [ "read" ]
      ).value[:secret]
    end

    it "read (GET error_groups): token senza 'read' → 403 R403-AUTH-002" do
      get "/api/v1/error_groups", headers: { "Authorization" => "Bearer #{ingest_only}" }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-AUTH-002")
    end

    it "ingest (POST events): token senza 'ingest' → 403 R403-AUTH-002" do
      post "/api/v1/projects/#{project.id}/events", params: body,
                                                    headers: { "Authorization" => "Bearer #{read_only}", "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-AUTH-002")
    end

    it "token a piena potenza (ingest+read) → legge E ingesta" do
      get "/api/v1/error_groups", headers: headers
      expect(response).to have_http_status(:ok)

      post "/api/v1/projects/#{project.id}/events", params: body, headers: headers
      expect(response).to have_http_status(:accepted)
    end
  end

  describe "risoluzione bearer + debounce di last_used_at" do
    it "bearer con token vuoto ('Bearer' + spazi) → 401 (presented blank)" do
      get "/api/v1/error_groups", headers: { "Authorization" => "Bearer   " }
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("R401-AUTH-001")
    end

    it "senza header Authorization → 401 (header nil)" do
      get "/api/v1/error_groups"
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("R401-AUTH-001")
    end

    it "header non-Bearer (Basic) → 401" do
      get "/api/v1/error_groups", headers: { "Authorization" => "Basic YWJjOjEyMw==" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "seconda richiesta entro il debounce → NON riscrive last_used_at (stale_usage? falso)" do
      freeze_time do
        get "/api/v1/error_groups", headers: { "Authorization" => "Bearer #{secret}" }
        token = Projects::Token.order(:created_at).last
        first_used = token.reload.last_used_at
        expect(first_used).to be_present # prima richiesta: last_used_at nil → stale → aggiornato

        get "/api/v1/error_groups", headers: { "Authorization" => "Bearer #{secret}" }
        expect(token.reload.last_used_at).to eq(first_used) # fresh → skip update
      end
    end
  end
end
