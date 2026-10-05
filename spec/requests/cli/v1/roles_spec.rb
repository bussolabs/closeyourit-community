# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Roles", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/roles"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (org-level permissions.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con i ruoli dell'org e meta" do
      role = create(:role, organization:, name: "Client")

      get "/cli/v1/roles", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |r| r["id"] }
      expect(ids).to include(role.id)
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "index esclude i ruoli di un'altra org (anti-BOLA)" do
      mine = create(:role, organization:)
      other = create(:role)

      get "/cli/v1/roles", headers: headers

      ids = response.parsed_body["data"].map { |r| r["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(other.id)
    end

    it "show → 200 con name e permission_keys" do
      role = create(:role, organization:, name: "Client")
      create(:role_permission, role:, permission_key: "tickets.edit")

      get "/cli/v1/roles/#{role.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["name"]).to eq("Client")
      expect(data["permission_keys"]).to include("tickets.edit")
    end

    it "show di un ruolo di un'altra org → 404 (anti-BOLA)" do
      other = create(:role)
      get "/cli/v1/roles/#{other.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "create → 201 e applica le permission_keys" do
      expect do
        post "/cli/v1/roles", headers: headers, params: { confirm: "1",
          name: "Client", color: "indigo",
          permission_keys: %w[tickets.edit tickets.assign tickets.attachments.manage tickets.comment.delete_any]
        }
      end.to change(Authorization::Role, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["name"]).to eq("Client")
      role = Authorization::Role.find(data["id"])
      expect(role.created_by).to eq(account)
      expect(role.permission_keys).to match_array(
        %w[tickets.edit tickets.assign tickets.attachments.manage tickets.comment.delete_any]
      )
    end

    it "create scarta le chiavi non valide (non nel Catalog)" do
      post "/cli/v1/roles", headers: headers, params: { confirm: "1",
        name: "Client", permission_keys: %w[tickets.edit nonexistent.key]
      }

      role = Authorization::Role.find(response.parsed_body["data"]["id"])
      expect(role.permission_keys).to eq(%w[tickets.edit])
    end

    it "update → 200 e ri-sincronizza le permission_keys" do
      role = create(:role, organization:, name: "Client")
      create(:role_permission, role:, permission_key: "tickets.edit")

      put "/cli/v1/roles/#{role.id}", headers: headers, params: { confirm: "1",
        name: "Client rinominato", permission_keys: %w[tickets.assign]
      }

      expect(response).to have_http_status(:ok)
      expect(role.reload.name).to eq("Client rinominato")
      expect(role.permission_keys).to eq(%w[tickets.assign])
    end

    it "update senza permission_keys non tocca i permessi" do
      role = create(:role, organization:, name: "Client")
      create(:role_permission, role:, permission_key: "tickets.edit")

      put "/cli/v1/roles/#{role.id}", headers: headers, params: { confirm: "1", color: "rose" }

      expect(response).to have_http_status(:ok)
      expect(role.reload.permission_keys).to eq(%w[tickets.edit])
    end

    it "destroy → 204" do
      role = create(:role, organization:)
      delete "/cli/v1/roles/#{role.id}", params: { confirm: "1" }, headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Authorization::Role).not_to exist(role.id)
    end

    it "create senza name → 422 R422-ROLE-001 con details" do
      post "/cli/v1/roles", headers: headers, params: { confirm: "1", color: "indigo" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ROLE-001")
      expect(response.parsed_body["error"]["details"]).to have_key("name")
    end

    it "update con name vuoto → 422 R422-ROLE-001 (ramo else)" do
      role = create(:role, organization:, name: "Client")

      put "/cli/v1/roles/#{role.id}", headers: headers, params: { confirm: "1", name: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ROLE-001")
      expect(role.reload.name).to eq("Client")
    end
  end

  context "membro senza permissions.manage" do
    before { create(:membership, account:, organization:, role: :member) }

    it "create → 403 R403-CLIAUTH-002" do
      post "/cli/v1/roles", headers: headers, params: { name: "X" }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "index → 403 (anche la lettura è gated permissions.manage)" do
      get "/cli/v1/roles", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
