# frozen_string_literal: true

require "rails_helper"

# CYSK-26 — il canale dell'estratto di copertura: la CI pubblica (upsert per branch), chi analizza
# rilegge. L'ultima fotografia, mai lo storico.
RSpec.describe "Api::V1::CoverageReports", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }
  let(:token) do
    Projects::Tokens::Issue.call(
      project:, name: "CI", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let(:payload) do
    { "files" => [ { "path" => "app/models/user.rb", "lines_relevant" => 10, "lines_covered" => 9,
                     "branches_total" => 4, "branches_covered" => 3, "never_loaded" => false } ],
      "uncovered_branches" => [ { "path" => "app/models/user.rb", "type" => "else", "line" => 7,
                                  "column" => 4, "parent_line_hits" => 412, "body_token" => "raise" } ],
      "run" => { "command" => "rspec", "minimum_coverage_line" => 90, "minimum_coverage_branch" => 90 } }
  end

  describe "POST /api/v1/projects/:id/coverage" do
    it "registra l'estratto per branch → 201, e ripubblicare AGGIORNA la stessa riga" do
      post "/api/v1/projects/#{project.id}/coverage", headers:, as: :json,
           params: { branch: "main", sha: "abc1234", captured_at: "2026-08-31T10:00:00Z",
                     line_covered_percent: 98.7, branch_covered_percent: 90.0,
                     files_count: 1, never_loaded_count: 0, payload: payload }

      expect(response).to have_http_status(:created)
      expect(project.coverage_reports.count).to eq(1)

      post "/api/v1/projects/#{project.id}/coverage", headers:, as: :json,
           params: { branch: "main", sha: "def5678", captured_at: "2026-08-31T11:00:00Z",
                     line_covered_percent: 99.0, files_count: 2, payload: payload }

      expect(response).to have_http_status(:created)
      report = project.coverage_reports.sole
      expect(report.sha).to eq("def5678")
      expect(report.files_count).to eq(2)
      expect(report.payload["uncovered_branches"].first["parent_line_hits"]).to eq(412)
    end

    it "senza branch → 422 con codice suo" do
      post "/api/v1/projects/#{project.id}/coverage", headers:, params: { sha: "abc" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-COVERAGE-001")
    end

    it "un payload oltre il tetto viene rifiutato: è il resultset intero, non l'estratto" do
      enorme = { "files" => [ { "path" => "x" * (Projects::CoverageReport::MAX_PAYLOAD_BYTES + 100) } ] }

      post "/api/v1/projects/#{project.id}/coverage", headers:, as: :json,
           params: { branch: "main", payload: enorme }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-COVERAGE-002")
      expect(project.coverage_reports.count).to eq(0)
    end

    it "senza token → 401" do
      post "/api/v1/projects/#{project.id}/coverage", params: { branch: "main" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/projects/:id/coverage" do
    it "rilegge l'estratto, filtrabile per branch" do
      create(:coverage_report, project:, branch: "main", payload: payload)
      create(:coverage_report, project:, branch: "develop")

      get "/api/v1/projects/#{project.id}/coverage", headers:, params: { branch: "main" }

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.size).to eq(1)
      expect(data.first["branch"]).to eq("main")
      expect(data.first["payload"]["run"]["minimum_coverage_line"]).to eq(90)
    end
  end
end
