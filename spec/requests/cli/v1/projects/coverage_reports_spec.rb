# frozen_string_literal: true

require "rails_helper"

# CYSK-26 — rilettura CLI dell'estratto di copertura: la visibilità del progetto è il gate.
RSpec.describe "Cli::V1::Projects::CoverageReports", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  describe "GET /cli/v1/projects/:project_id/coverage" do
    it "rilegge gli estratti del progetto, filtrabili per branch" do
      create(:coverage_report, project:, branch: "main", line_covered_percent: 98.78)
      create(:coverage_report, project:, branch: "develop")

      get "/cli/v1/projects/#{project.id}/coverage", headers:, params: { branch: "main" }

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.size).to eq(1)
      expect(data.first["line_covered_percent"]).to eq("98.78")
    end

    it "progetto di un'altra organizzazione → 404 (anti-BOLA)" do
      estraneo = create(:project, organization: create(:organization))

      get "/cli/v1/projects/#{estraneo.id}/coverage", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
