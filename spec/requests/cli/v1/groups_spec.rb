# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Groups", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/groups"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (org-level project_groups.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con i gruppi dell'org e meta di paginazione" do
      g = create(:group, organization:)

      get "/cli/v1/groups", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(g.id)
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "index esclude i gruppi di un'altra org (anti-BOLA)" do
      mine = create(:group, organization:)
      other = create(:group) # altra org

      get "/cli/v1/groups", headers: headers

      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(other.id)
    end

    it "show → 200 con id e name" do
      g = create(:group, organization:, name: "DriverOne")

      get "/cli/v1/groups/#{g.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["id"]).to eq(g.id)
      expect(data["name"]).to eq("DriverOne")
    end

    it "show di un gruppo di un'altra org → 404 (anti-BOLA)" do
      other = create(:group)

      get "/cli/v1/groups/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
    end

    it "create → 201 e crea il gruppo" do
      expect do
        post "/cli/v1/groups", headers: headers, params: { name: "DriverOne", color: "indigo" }
      end.to change(Projects::Group, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["name"]).to eq("DriverOne")
      expect(Projects::Group.find(data["id"]).created_by).to eq(account)
    end

    it "create con icona Font Awesome la salva" do
      post "/cli/v1/groups", headers: headers, params: { name: "G", color: "indigo", icon: "rocket" }
      expect(Projects::Group.find(response.parsed_body["data"]["id"]).icon).to eq("rocket")
    end

    it "create senza name → 422 R422-GROUP-001 con details" do
      post "/cli/v1/groups", headers: headers, params: { color: "indigo" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-GROUP-001")
      expect(response.parsed_body["error"]["details"]).to have_key("name")
    end
  end

  context "membro senza project_groups.view" do
    before { create(:membership, account:, organization:, role: :member) }

    it "create → 403 R403-CLIAUTH-002" do
      post "/cli/v1/groups", headers: headers, params: { name: "X" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "index → 403 (lettura gata da project_groups.view)" do
      get "/cli/v1/groups", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "show → 403 (lettura gata da project_groups.view)" do
      g = create(:group, organization:)
      get "/cli/v1/groups/#{g.id}", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "membro con project_groups.view ma visibilità ristretta" do
    let(:owner_account) { create(:account) }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:membership, account: owner_account, organization:, role: :owner)
      Authorization::SetAccountPermissions.call(organization:, account:,
                                                allow_keys: [ "project_groups.view" ], actor: owner_account)
    end

    # La falla chiusa: prima il canale CLI enumerava TUTTI i gruppi dell'org anche a un token ristretto.
    it "index gata + scopato: vede SOLO i gruppi assegnati, non tutti (anti-leak)" do
      assigned = create(:group, organization:)
      hidden = create(:group, organization:)
      Connections::SetMemberAccess.call(organization:, account:, group_ids: [ assigned.id ], project_ids: [])

      get "/cli/v1/groups", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(assigned.id)
      expect(ids).not_to include(hidden.id)
    end
  end

  describe "PUT update (project_groups.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:group) { create(:group, organization:, name: "Old") }

    it "owner aggiorna → 200 + nome nuovo" do
      put "/cli/v1/groups/#{group.id}", headers: headers, params: { name: "New", color: "indigo" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["name"]).to eq("New")
      expect(group.reload.name).to eq("New")
    end

    it "validazione fallita → 422 R422-GROUP-001" do
      put "/cli/v1/groups/#{group.id}", headers: headers, params: { name: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-GROUP-001")
    end

    it "gruppo di un'altra organizzazione → 404 (anti-BOLA)" do
      other = create(:group)

      put "/cli/v1/groups/#{other.id}", headers: headers, params: { name: "X" }

      expect(response).to have_http_status(:not_found)
    end

    it "membro senza project_groups.manage → 403" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      put "/cli/v1/groups/#{group.id}", headers: { "Authorization" => "Bearer #{member_secret}" },
                                        params: { name: "X" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "senza bearer → 401" do
      put "/cli/v1/groups/#{group.id}", params: { name: "X" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE destroy (project_groups.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let!(:group) { create(:group, organization:) }

    it "owner elimina → 204 e gruppo rimosso" do
      delete "/cli/v1/groups/#{group.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Projects::Group.exists?(group.id)).to be(false)
    end

    it "gruppo di un'altra organizzazione → 404 (anti-BOLA)" do
      other = create(:group)

      delete "/cli/v1/groups/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "membro senza project_groups.manage → 403" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      delete "/cli/v1/groups/#{group.id}", headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end
end
