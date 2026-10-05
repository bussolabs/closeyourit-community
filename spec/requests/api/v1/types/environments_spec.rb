require "rails_helper"

RSpec.describe "Api::V1::Types::Environments", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  # Il token si lega a un environment DICHIARATO dal progetto: usiamo uno dei default (production),
  # così la lista resta i 3 default senza un quarto environment estraneo.
  let(:environment) do
    organization.environments.find_by(code: "production").tap { |e| project.environments << e }
  end
  let(:secret) do
    Projects::Tokens::Issue.call(
      project:, name: "SDK", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { Types::InstallDefaults.call(organization:) }

  describe "GET /api/v1/types/environments" do
    it "senza token → 401 con envelope R401-AUTH-001" do
      get "/api/v1/types/environments"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("R401-AUTH-001")
    end

    it "con token revocato → 401" do
      token = Projects::Token.active.find_by(token_digest: Digest::SHA256.hexdigest(secret))
      Projects::Tokens::Revoke.call(token:)

      get "/api/v1/types/environments", headers: headers

      expect(response).to have_http_status(:unauthorized)
    end

    it "con token valido → 200 ed envelope { data: [...] } con gli environment dell'org" do
      get "/api/v1/types/environments", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to be_an(Array)
      expect(data.map { |e| e["code"] }).to match_array(%w[production staging development])
      expect(data.first).to include("id", "code", "label", "color")
    end

    it "BOLA: il token vede SOLO gli environment della propria org, non di un'altra org" do
      other_org = create(:organization)
      Types::InstallDefaults.call(organization: other_org)
      other_org.environments.find_by(code: "development").update!(label: "Altro Env")

      get "/api/v1/types/environments", headers: headers

      labels = response.parsed_body["data"].map { |e| e["label"] }
      expect(labels).not_to include("Altro Env")
    end

    it "aggiorna last_used_at del token al primo uso" do
      token = Projects::Token.active.find_by(token_digest: Digest::SHA256.hexdigest(secret))
      expect(token.last_used_at).to be_nil

      get "/api/v1/types/environments", headers: headers

      expect(token.reload.last_used_at).to be_present
    end
  end
end
