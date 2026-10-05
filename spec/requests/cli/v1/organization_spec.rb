# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Organization", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization, name: "Acme", slug: "acme") }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "show senza bearer → 401" do
    get "/cli/v1/organization"
    expect(response).to have_http_status(:unauthorized)
  end

  it "update senza bearer → 401" do
    put "/cli/v1/organization", params: { name: "X" }
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (organization.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "show → 200 con id, name e slug della propria org" do
      get "/cli/v1/organization", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["id"]).to eq(organization.id)
      expect(data["name"]).to eq("Acme")
      expect(data["slug"]).to eq("acme")
    end

    it "update → 200 + nome nuovo" do
      put "/cli/v1/organization", headers: headers, params: { confirm: "1", name: "Acme Renamed", slug: "acme-renamed" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["name"]).to eq("Acme Renamed")
      expect(response.parsed_body["data"]["slug"]).to eq("acme-renamed")
      expect(organization.reload.name).to eq("Acme Renamed")
      expect(organization.slug).to eq("acme-renamed")
    end

    it "update imposta la retention org (log/analytics) — parità Member" do
      put "/cli/v1/organization", headers: headers,
                                  params: { confirm: "1", logs_retention_days: 30, analytics_retention_days: 90 }

      expect(response).to have_http_status(:ok)
      expect(organization.reload.logs_retention_days).to eq(30)
      expect(organization.analytics_retention_days).to eq(90)
    end

    it "update imposta la retention org errori/performance/server/uptime (CYRA-159) — parità Member" do
      put "/cli/v1/organization", headers: headers,
                                  params: { confirm: "1", errors_retention_days: 90, performance_retention_days: 60,
                                            servers_retention_days: 15, uptime_retention_days: 365 }

      expect(response).to have_http_status(:ok)
      organization.reload
      expect(organization.errors_retention_days).to eq(90)
      expect(organization.performance_retention_days).to eq(60)
      expect(organization.servers_retention_days).to eq(15)
      expect(organization.uptime_retention_days).to eq(365)
    end

    it "retention servers fuori range → 422 R422-ORGANIZATION-001" do
      put "/cli/v1/organization", headers: headers, params: { confirm: "1", servers_retention_days: 999 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ORGANIZATION-001")
    end

    it "validazione fallita → 422 R422-ORGANIZATION-001 con details" do
      put "/cli/v1/organization", headers: headers, params: { confirm: "1", name: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ORGANIZATION-001")
      expect(response.parsed_body["error"]["details"]).to have_key("name")
      expect(organization.reload.name).to eq("Acme")
    end
  end

  context "membro senza organization.manage" do
    before { create(:membership, account:, organization:, role: :member) }

    it "show → 403 (settings org gatate come nel web; l'identità resta in whoami)" do
      get "/cli/v1/organization", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "update → 403 R403-CLIAUTH-002" do
      put "/cli/v1/organization", headers: headers, params: { name: "X" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end
end
