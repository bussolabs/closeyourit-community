require "rails_helper"

RSpec.describe "Api::V1::Types::Platforms", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(
      project:, name: "SDK", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { Types::InstallDefaults.call(organization:) }

  describe "GET /api/v1/types/platforms" do
    it "senza token → 401 con envelope R401-AUTH-001" do
      get "/api/v1/types/platforms"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("R401-AUTH-001")
    end

    it "con token revocato → 401" do
      token = Projects::Token.active.find_by(token_digest: Digest::SHA256.hexdigest(secret))
      Projects::Tokens::Revoke.call(token:)

      get "/api/v1/types/platforms", headers: headers

      expect(response).to have_http_status(:unauthorized)
    end

    it "con token valido → 200 ed envelope { data: [...] } con le piattaforme dell'org" do
      get "/api/v1/types/platforms", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to be_an(Array)
      expect(data.map { |p| p["code"] }).to match_array(%w[ios android web])
      expect(data.first).to include("id", "code", "label", "color", "supports_uptime")
    end

    it "espone la capability supports_uptime (web true, ios/android false)" do
      get "/api/v1/types/platforms", headers: headers

      by_code = response.parsed_body["data"].index_by { |p| p["code"] }
      expect(by_code["web"]["supports_uptime"]).to be(true)
      expect(by_code["ios"]["supports_uptime"]).to be(false)
      expect(by_code["android"]["supports_uptime"]).to be(false)
    end

    it "BOLA: il token vede SOLO le piattaforme della propria org, non di un'altra org" do
      other_org = create(:organization)
      Types::InstallDefaults.call(organization: other_org)
      other_org.platforms.find_by(code: "web").update!(label: "Altro Web")

      get "/api/v1/types/platforms", headers: headers

      labels = response.parsed_body["data"].map { |p| p["label"] }
      expect(labels).not_to include("Altro Web")
    end

    it "aggiorna last_used_at del token al primo uso" do
      token = Projects::Token.active.find_by(token_digest: Digest::SHA256.hexdigest(secret))
      expect(token.last_used_at).to be_nil

      get "/api/v1/types/platforms", headers: headers

      expect(token.reload.last_used_at).to be_present
    end
  end
end
