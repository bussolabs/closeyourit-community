require "rails_helper"

RSpec.describe "Api::V1::Types::TicketPriorities", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(project:, name: "SDK", host: "h", environment:).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { Types::InstallDefaults.call(organization:) }

  describe "GET /api/v1/types/ticket_priorities" do
    it "senza token → 401" do
      get "/api/v1/types/ticket_priorities"
      expect(response).to have_http_status(:unauthorized)
    end

    it "con token → 200 con le priorità dell'org" do
      get "/api/v1/types/ticket_priorities", headers: headers
      expect(response).to have_http_status(:ok)
      codes = response.parsed_body["data"].map { |p| p["code"] }
      expect(codes).to match_array(%w[low medium high])
    end
  end
end
