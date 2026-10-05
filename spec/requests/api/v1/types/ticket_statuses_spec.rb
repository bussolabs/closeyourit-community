require "rails_helper"

RSpec.describe "Api::V1::Types::TicketStatuses", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(project:, name: "SDK", host: "h", environment:).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { Types::InstallDefaults.call(organization:) }

  describe "GET /api/v1/types/ticket_statuses" do
    it "senza token → 401" do
      get "/api/v1/types/ticket_statuses"
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("R401-AUTH-001")
    end

    it "con token → 200 con gli status dell'org" do
      get "/api/v1/types/ticket_statuses", headers: headers
      expect(response).to have_http_status(:ok)
      codes = response.parsed_body["data"].map { |s| s["code"] }
      expect(codes).to include("open", "in_progress", "resolved")
      expect(response.parsed_body["data"].first).to include("animated")
    end
  end
end
