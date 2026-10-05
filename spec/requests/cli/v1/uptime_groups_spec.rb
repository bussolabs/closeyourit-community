# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::UptimeGroups", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/uptime_groups"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (uptime_groups.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con i gruppi dell'org e meta di paginazione" do
      g = create(:uptime_group, organization:)

      get "/cli/v1/uptime_groups", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(g.id)
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "index esclude i gruppi di un'altra org (anti-BOLA)" do
      mine = create(:uptime_group, organization:)
      other = create(:uptime_group)

      get "/cli/v1/uptime_groups", headers: headers

      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(other.id)
    end

    it "show → 200 con id, name e public_status_enabled" do
      g = create(:uptime_group, organization:, name: "Edge")

      get "/cli/v1/uptime_groups/#{g.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["id"]).to eq(g.id)
      expect(data["name"]).to eq("Edge")
      expect(data).to have_key("public_status_enabled")
    end

    it "show di un gruppo di un'altra org → 404 (anti-BOLA)" do
      other = create(:uptime_group)

      get "/cli/v1/uptime_groups/#{other.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
    end

    it "create → 201 e crea il gruppo con created_by" do
      expect do
        post "/cli/v1/uptime_groups", headers: headers, params: { confirm: "1", name: "Frontend", color: "indigo" }
      end.to change(Uptime::Group, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["name"]).to eq("Frontend")
      expect(Uptime::Group.find(data["id"]).created_by).to eq(account)
    end

    it "create senza name → 422 R422-UPTIMEGROUP-001 con details" do
      post "/cli/v1/uptime_groups", headers: headers, params: { confirm: "1", color: "indigo" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-UPTIMEGROUP-001")
      expect(response.parsed_body["error"]["details"]).to have_key("name")
    end

    it "update → 200 + nome nuovo" do
      g = create(:uptime_group, organization:, name: "Old")

      put "/cli/v1/uptime_groups/#{g.id}", headers: headers, params: { confirm: "1", name: "New" }

      expect(response).to have_http_status(:ok)
      expect(g.reload.name).to eq("New")
    end

    it "destroy → 204 e gruppo rimosso" do
      g = create(:uptime_group, organization:)

      delete "/cli/v1/uptime_groups/#{g.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Uptime::Group.exists?(g.id)).to be(false)
    end

    it "PUT publication → 200 e public_status_enabled true" do
      g = create(:uptime_group, organization:)

      put "/cli/v1/uptime_groups/#{g.id}/publication", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["public_status_enabled"]).to be(true)
      expect(g.reload.public_status_enabled).to be(true)
    end

    it "DELETE publication → 200 e public_status_enabled false" do
      g = create(:uptime_group, :published, organization:)

      delete "/cli/v1/uptime_groups/#{g.id}/publication", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(g.reload.public_status_enabled).to be(false)
    end
  end

  context "membro con uptime_groups.view" do
    let(:owner_account) { create(:account) }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:membership, account: owner_account, organization:, role: :owner)
      Authorization::SetAccountPermissions.call(organization:, account:,
                                                allow_keys: [ "uptime_groups.view" ], actor: owner_account)
    end

    it "index → 200 (lettura consentita da uptime_groups.view)" do
      create(:uptime_group, organization:)
      get "/cli/v1/uptime_groups", headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "create → 403 (serve uptime_groups.manage)" do
      post "/cli/v1/uptime_groups", headers: headers, params: { name: "X" }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "publication → 403 (serve uptime_groups.manage)" do
      g = create(:uptime_group, organization:)
      put "/cli/v1/uptime_groups/#{g.id}/publication", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "membro senza uptime_groups.view" do
    before { create(:membership, account:, organization:, role: :member) }

    it "index → 403 (lettura gata da uptime_groups.view)" do
      get "/cli/v1/uptime_groups", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "show → 403" do
      g = create(:uptime_group, organization:)
      get "/cli/v1/uptime_groups/#{g.id}", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
