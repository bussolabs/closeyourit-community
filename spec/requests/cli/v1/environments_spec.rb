# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Environments", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/environments"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (org-level environments.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con gli environment dell'org e meta di paginazione" do
      env = create(:environment, organization:, code: "production")

      get "/cli/v1/environments", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(env.id)
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "index esclude gli environment di un'altra org (anti-BOLA)" do
      mine = create(:environment, organization:, code: "production")
      other = create(:environment) # altra org

      get "/cli/v1/environments", headers: headers

      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(other.id)
    end

    it "show per id → 200 con code e label" do
      env = create(:environment, organization:, code: "staging", label: "Staging")

      get "/cli/v1/environments/#{env.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["id"]).to eq(env.id)
      expect(data["code"]).to eq("staging")
      expect(data["label"]).to eq("Staging")
    end

    it "show per code → 200 (il backend risolve id-or-code)" do
      env = create(:environment, organization:, code: "production")

      get "/cli/v1/environments/production", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["id"]).to eq(env.id)
    end

    it "show di un environment di un'altra org → 404 (anti-BOLA)" do
      other = create(:environment)

      get "/cli/v1/environments/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
    end

    it "create → 201 e crea l'environment con created_by" do
      expect do
        post "/cli/v1/environments", headers: headers,
                                     params: { code: "production", label: "Production", color: "indigo" }
      end.to change(Types::Environment, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["code"]).to eq("production")
      expect(Types::Environment.find(data["id"]).created_by).to eq(account)
    end

    it "create imposta e serializza i default di capability" do
      post "/cli/v1/environments", headers: headers,
                                   params: { code: "qa", label: "QA", color: "sky",
                                             servers_enabled: "1", uptime_enabled: "0", secrets_enabled: "1" }

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect([ data["servers_enabled"], data["uptime_enabled"], data["secrets_enabled"] ]).to eq([ true, false, true ])
      env = Types::Environment.find(data["id"])
      expect([ env.servers_enabled, env.uptime_enabled, env.secrets_enabled ]).to eq([ true, false, true ])
    end

    it "create senza code → 422 R422-ENVIRONMENT-001 con details" do
      post "/cli/v1/environments", headers: headers, params: { label: "Production", color: "indigo" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ENVIRONMENT-001")
      expect(response.parsed_body["error"]["details"]).to have_key("code")
    end
  end

  describe "PUT update (environments.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:environment) { create(:environment, organization:, code: "staging", label: "Old") }

    it "owner aggiorna → 200 + label nuova" do
      put "/cli/v1/environments/#{environment.id}", headers: headers, params: { label: "New" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["label"]).to eq("New")
      expect(environment.reload.label).to eq("New")
    end

    it "aggiorna risolvendo per code nel path → 200" do
      environment

      put "/cli/v1/environments/staging", headers: headers, params: { color: "amber" }

      expect(response).to have_http_status(:ok)
      expect(environment.reload.color).to eq("amber")
    end

    it "validazione fallita → 422 R422-ENVIRONMENT-001" do
      put "/cli/v1/environments/#{environment.id}", headers: headers, params: { label: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ENVIRONMENT-001")
    end

    it "environment di un'altra organizzazione → 404 (anti-BOLA)" do
      other = create(:environment)

      put "/cli/v1/environments/#{other.id}", headers: headers, params: { label: "X" }

      expect(response).to have_http_status(:not_found)
    end

    it "membro senza environments.manage → 403 R403-CLIAUTH-002" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      put "/cli/v1/environments/#{environment.id}", headers: { "Authorization" => "Bearer #{member_secret}" },
                                                    params: { label: "X" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      put "/cli/v1/environments/#{environment.id}", params: { label: "X" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE destroy (environments.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let!(:environment) { create(:environment, organization:) }

    it "owner elimina → 204 e environment rimosso" do
      delete "/cli/v1/environments/#{environment.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Types::Environment.exists?(environment.id)).to be(false)
    end

    it "owner elimina per code → 204 (risoluzione id-or-code)" do
      target = create(:environment, organization:, code: "legacy")

      delete "/cli/v1/environments/legacy", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Types::Environment.exists?(target.id)).to be(false)
    end

    it "environment referenziato da un progetto → 422 R422-ENVIRONMENT-001 (restrict_with_error)" do
      project = create(:project, organization:)
      create(:project_environment, project:, environment:)

      delete "/cli/v1/environments/#{environment.id}", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ENVIRONMENT-001")
      expect(Types::Environment.exists?(environment.id)).to be(true)
    end

    it "environment di un'altra organizzazione → 404 (anti-BOLA)" do
      other = create(:environment)

      delete "/cli/v1/environments/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "membro senza environments.manage → 403" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      delete "/cli/v1/environments/#{environment.id}", headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  context "membro senza environments.view" do
    before { create(:membership, account:, organization:, role: :member) }

    it "index → 403 (lettura gata da environments.view)" do
      get "/cli/v1/environments", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "create → 403 R403-CLIAUTH-002" do
      post "/cli/v1/environments", headers: headers, params: { code: "production", label: "Production", color: "indigo" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  context "membro con environments.view" do
    let(:owner_account) { create(:account) }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:membership, account: owner_account, organization:, role: :owner)
      Authorization::SetAccountPermissions.call(organization:, account:,
                                                allow_keys: [ "environments.view" ], actor: owner_account)
    end

    it "index → 200 (lettura consentita da environments.view)" do
      create(:environment, organization:, code: "production")
      get "/cli/v1/environments", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end
end
