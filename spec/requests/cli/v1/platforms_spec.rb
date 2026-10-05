# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Platforms", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/platforms"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (org-level platforms.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con le piattaforme dell'org e meta di paginazione" do
      p = create(:platform, organization:)

      get "/cli/v1/platforms", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(p.id)
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "index esclude le piattaforme di un'altra org (anti-BOLA)" do
      mine = create(:platform, organization:)
      other = create(:platform) # altra org

      get "/cli/v1/platforms", headers: headers

      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(other.id)
    end

    it "show per id → 200 con id e code" do
      p = create(:platform, organization:, code: "ios", label: "iOS")

      get "/cli/v1/platforms/#{p.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["id"]).to eq(p.id)
      expect(data["code"]).to eq("ios")
    end

    it "show per code → 200 (risoluzione id-or-code)" do
      p = create(:platform, organization:, code: "macos", label: "macOS")

      get "/cli/v1/platforms/macos", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["id"]).to eq(p.id)
    end

    it "show di una piattaforma di un'altra org → 404 (anti-BOLA)" do
      other = create(:platform)

      get "/cli/v1/platforms/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
    end

    it "show di un code di un'altra org → 404 (anti-BOLA)" do
      create(:platform, code: "windows") # altra org

      get "/cli/v1/platforms/windows", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "create → 201 e crea la piattaforma" do
      expect do
        post "/cli/v1/platforms", headers: headers,
                                  params: { code: "linux", label: "Linux", color: "indigo" }
      end.to change(Types::Platform, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["code"]).to eq("linux")
      expect(Types::Platform.find(data["id"]).created_by).to eq(account)
    end

    it "create senza code/color → 422 R422-PLATFORM-001 con details" do
      post "/cli/v1/platforms", headers: headers, params: { label: "X" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PLATFORM-001")
      expect(response.parsed_body["error"]["details"]).to have_key("code")
    end

    it "create imposta supports_uptime — parità Member" do
      post "/cli/v1/platforms", headers: headers,
                                params: { code: "srv", label: "Server", color: "sky", supports_uptime: true }

      expect(response).to have_http_status(:created)
      expect(Types::Platform.find(response.parsed_body["data"]["id"]).supports_uptime).to be(true)
    end
  end

  context "membro senza platforms.view" do
    before { create(:membership, account:, organization:, role: :member) }

    it "create → 403 R403-CLIAUTH-002" do
      post "/cli/v1/platforms", headers: headers, params: { code: "x", label: "X", color: "sky" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "index → 403 (lettura gata da platforms.view)" do
      get "/cli/v1/platforms", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  context "membro con platforms.view" do
    let(:owner_account) { create(:account) }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:membership, account: owner_account, organization:, role: :owner)
      Authorization::SetAccountPermissions.call(organization:, account:,
                                                allow_keys: [ "platforms.view" ], actor: owner_account)
    end

    it "index → 200 (lettura consentita da platforms.view)" do
      create(:platform, organization:)
      get "/cli/v1/platforms", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PUT update (platforms.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    let(:platform) { create(:platform, organization:, code: "web", label: "Old") }

    it "owner aggiorna per id → 200 + label nuova" do
      put "/cli/v1/platforms/#{platform.id}", headers: headers, params: { label: "New" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["label"]).to eq("New")
      expect(platform.reload.label).to eq("New")
    end

    it "owner aggiorna per code → 200 (risoluzione id-or-code)" do
      put "/cli/v1/platforms/#{platform.code}", headers: headers, params: { color: "indigo" }

      expect(response).to have_http_status(:ok)
      expect(platform.reload.color).to eq("indigo")
    end

    it "validazione fallita → 422 R422-PLATFORM-001" do
      put "/cli/v1/platforms/#{platform.id}", headers: headers, params: { label: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PLATFORM-001")
    end

    it "piattaforma di un'altra organizzazione → 404 (anti-BOLA)" do
      other = create(:platform)

      put "/cli/v1/platforms/#{other.id}", headers: headers, params: { label: "X" }

      expect(response).to have_http_status(:not_found)
    end

    it "membro senza platforms.manage → 403" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      put "/cli/v1/platforms/#{platform.id}", headers: { "Authorization" => "Bearer #{member_secret}" },
                                              params: { label: "X" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      put "/cli/v1/platforms/#{platform.id}", params: { label: "X" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE destroy (platforms.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    let!(:platform) { create(:platform, organization:) }

    it "owner elimina per id → 204 e piattaforma rimossa" do
      delete "/cli/v1/platforms/#{platform.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Types::Platform.exists?(platform.id)).to be(false)
    end

    it "owner elimina per code → 204 (risoluzione id-or-code)" do
      target = create(:platform, organization:, code: "legacy")

      delete "/cli/v1/platforms/legacy", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Types::Platform.exists?(target.id)).to be(false)
    end

    it "piattaforma referenziata da un progetto → 422 R422-PLATFORM-001 (restrict_with_error)" do
      create(:project, organization:).platforms << platform

      delete "/cli/v1/platforms/#{platform.id}", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PLATFORM-001")
      expect(Types::Platform.exists?(platform.id)).to be(true)
    end

    it "piattaforma di un'altra organizzazione → 404 (anti-BOLA)" do
      other = create(:platform)

      delete "/cli/v1/platforms/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "membro senza platforms.manage → 403" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      delete "/cli/v1/platforms/#{platform.id}", headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end
end
