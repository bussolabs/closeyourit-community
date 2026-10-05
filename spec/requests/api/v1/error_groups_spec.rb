# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::ErrorGroups", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(
      project:, name: "SDK", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  describe "scope del token (CYRA-37)" do
    let(:ingest_only_secret) do
      Projects::Tokens::Issue.call(
        project:, name: "SDK ingest-only", host: "bugs.example.com",
        environment:, scopes: [ "ingest" ]
      ).value[:secret]
    end

    it "un token scoped solo 'ingest' → 403 R403-AUTH-002 (nessuna lettura della telemetria)" do
      create(:error_group, project:)
      get "/api/v1/error_groups", headers: { "Authorization" => "Bearer #{ingest_only_secret}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-AUTH-002")
    end

    it "un token con scope 'read' (default Issue) → 200: la lettura richiede lo scope 'read'" do
      create(:error_group, project:)
      get "/api/v1/error_groups", headers: headers

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/error_groups" do
    it "senza token → 401" do
      get "/api/v1/error_groups"
      expect(response).to have_http_status(:unauthorized)
    end

    it "ritorna SOLO i gruppi del progetto del token (envelope data), ordinati per last_seen desc" do
      older = create(:error_group, project:, last_seen_at: 2.hours.ago)
      newer = create(:error_group, project:, last_seen_at: 1.minute.ago)
      create(:error_group, project: create(:project, organization:))   # altro progetto, NON visibile

      get "/api/v1/error_groups", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |g| g["id"] }
      expect(ids).to eq([ newer.id, older.id ])
      expect(response.parsed_body["data"].first).to include("title", "level", "status", "events_count", "promoted")
    end

    it "filtra per status" do
      create(:error_group, project:, status: :unresolved)
      resolved = create(:error_group, project:, status: :resolved)
      get "/api/v1/error_groups", params: { status: "resolved" }, headers: headers
      ids = response.parsed_body["data"].map { |g| g["id"] }
      expect(ids).to eq([ resolved.id ])
    end

    it "pagina i risultati (default 10) e ritorna meta invece di serializzare tutto" do
      create_list(:error_group, 12, project:)
      get "/api/v1/error_groups", headers: headers
      expect(response.parsed_body["data"].length).to eq(10)
      expect(response.parsed_body["meta"]).to include(
        "page" => 1, "per" => 10, "total" => 12, "total_pages" => 2
      )

      get "/api/v1/error_groups", params: { page: 2 }, headers: headers
      expect(response.parsed_body["data"].length).to eq(2)
      expect(response.parsed_body.dig("meta", "page")).to eq(2)
    end

    # CYRA-738 — la stessa lista dalla riga di comando preloadava l'assegnatario, questa no: il
    # serializer stampa l'assegnatario di ogni gruppo, quindi da qui partiva una lettura in più per
    # ogni riga. La domanda ai dati ora è una sola per entrambi i canali, e il preload viene con lei.
    it "non interroga l'assegnatario una volta per gruppo (gate Prosopite)" do
      # Setup bulk fuori dallo scan: sono INSERT di fixture, non l'N+1 di produzione che si misura.
      allow_n_plus_one do
        3.times do |i|
          assignee = create(:account, email: "assegnato-#{i}@example.com")
          create(:membership, account: assignee, organization:, role: :member)
          create(:error_group, project:, assignee:)
        end
      end

      get "/api/v1/error_groups", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |g| g["assignee"] }).to all(be_present)
    end

    it "cappa il per massimo (anti-DoS ?per=enorme)" do
      create_list(:error_group, 3, project:)
      get "/api/v1/error_groups", params: { per: 100_000 }, headers: headers
      expect(response.parsed_body.dig("meta", "per")).to eq(Pagination::MAX_PER)
      expect(response.parsed_body["data"].length).to eq(3)
    end
  end

  describe "GET /api/v1/error_groups/:id" do
    it "gruppo del progetto → 200" do
      group = create(:error_group, project:)
      get "/api/v1/error_groups/#{group.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "id")).to eq(group.id)
    end

    it "BOLA: gruppo di un altro progetto → 404" do
      foreign = create(:error_group, project: create(:project, organization:))
      get "/api/v1/error_groups/#{foreign.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "triage" do
    let(:group) { create(:error_group, project:, status: :unresolved) }

    it "PUT resolution → resolved" do
      put "/api/v1/error_groups/#{group.id}/resolution", headers: headers
      expect(response).to have_http_status(:ok)
      expect(group.reload).to be_status_resolved
    end

    it "DELETE resolution → reopen (unresolved)" do
      group.status_resolved!
      delete "/api/v1/error_groups/#{group.id}/resolution", headers: headers
      expect(group.reload).to be_status_unresolved
    end

    it "PUT mute → ignored" do
      put "/api/v1/error_groups/#{group.id}/mute", headers: headers
      expect(group.reload).to be_status_ignored
    end

    it "DELETE mute → reopen (unresolved)" do
      group.status_ignored!
      delete "/api/v1/error_groups/#{group.id}/mute", headers: headers
      expect(group.reload).to be_status_unresolved
    end

    it "BOLA: triage di un gruppo di un altro progetto → 404" do
      foreign = create(:error_group, project: create(:project, organization:))
      put "/api/v1/error_groups/#{foreign.id}/resolution", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "BOLA: mute (PUT e DELETE) di un gruppo di un altro progetto → 404, stato invariato" do
      foreign = create(:error_group, project: create(:project, organization:), status: :unresolved)
      put "/api/v1/error_groups/#{foreign.id}/mute", headers: headers
      expect(response).to have_http_status(:not_found)
      delete "/api/v1/error_groups/#{foreign.id}/mute", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload).to be_status_unresolved
    end
  end
end
