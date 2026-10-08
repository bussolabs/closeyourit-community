# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Agents skill releases", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before do
    create(:skill_release, version: "1.0.0")
    create(:skill_release, version: "1.1.0")
  end

  it "needs a bearer" do
    get "/cli/v1/agents/skill_release"

    expect(response).to have_http_status(:unauthorized)
  end

  context "member with only agents.view" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:account_permission, account:, organization:, permission_key: "agents.view", effect: :allow)
    end

    it "reads the list and the resolved version" do
      get "/cli/v1/agents/skill_releases", headers: headers
      expect(response).to have_http_status(:ok)

      get "/cli/v1/agents/skill_release", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end

  context "member without any agents key" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:account_permission, account:, organization:, permission_key: "agents.view", effect: :deny)
    end

    it "cannot read the list or the resolved version" do
      get "/cli/v1/agents/skill_releases", headers: headers
      expect(response).to have_http_status(:forbidden)

      get "/cli/v1/agents/skill_release", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "member without agents.manage" do
    before { create(:membership, account:, organization:, role: :member) }

    it "cannot pin" do
      put "/cli/v1/agents/skill_release_pin?confirm=1", params: { version: "1.0.0" }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(organization.reload.skill_release_pin).to be_nil
    end
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "lists versions newest first" do
      get "/cli/v1/agents/skill_releases", headers: headers

      expect(response.parsed_body["data"].map { _1["version"] }).to eq(%w[1.1.0 1.0.0])
    end

    it "resolves to the latest, then to the pinned version, then back" do
      get "/cli/v1/agents/skill_release", headers: headers
      expect(response.parsed_body["data"]).to include("version" => "1.1.0", "pinned" => false)

      put "/cli/v1/agents/skill_release_pin?confirm=1", params: { version: "1.0.0" }, headers: headers
      expect(response).to have_http_status(:ok)
      get "/cli/v1/agents/skill_release", headers: headers
      expect(response.parsed_body["data"]).to include("version" => "1.0.0", "pinned" => true)

      delete "/cli/v1/agents/skill_release_pin?confirm=1", headers: headers
      expect(response.parsed_body["data"]).to eq("version" => nil)
    end

    it "asks for confirmation before pinning" do
      put "/cli/v1/agents/skill_release_pin", params: { version: "1.0.0" }, headers: headers

      expect(response.body).to include("R422-CONFIRM-001")
    end

    it "refuses an unknown version" do
      put "/cli/v1/agents/skill_release_pin?confirm=1", params: { version: "9.9.9" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("R422-AGENT-010")
    end
  end
end
