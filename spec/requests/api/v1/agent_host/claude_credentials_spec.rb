# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::AgentHost::ClaudeCredentials", type: :request do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:plain) { "cyi_ah_plain_secret_value" }
  let(:path) { "/api/v1/agent_host/claude_credential" }
  let(:headers) { { "Authorization" => "Bearer #{plain}" } }

  before { create(:agent_host_token, host:, token_digest: Digest::SHA256.hexdigest(plain)) }

  it "serves the organization's credential to a certified host" do
    create(:agent_claude_credential, :oauth, organization:, token: "sk-ant-oat01-served")

    get path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body["data"]).to eq(
      "kind" => "oauth_token", "env" => "CLAUDE_CODE_OAUTH_TOKEN", "token" => "sk-ant-oat01-served"
    )
  end

  it "answers 404 when the organization has no credential" do
    get path, headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body["error"]["code"]).to eq("R404-AGENT-005")
  end

  it "refuses an uncertified host" do
    host.update!(certified_at: nil)
    create(:agent_claude_credential, organization:)

    get path, headers: headers

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]["code"]).to eq("R403-AGENT-003")
    expect(response.body).not_to include("sk-ant-")
  end

  it "never serves another organization's credential" do
    create(:agent_claude_credential, organization: create(:organization))

    get path, headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it "refuses an organization token (cyi_a_)" do
    org_plain = "cyi_a_org_secret_value"
    create(:agent_token, organization:, token_digest: Digest::SHA256.hexdigest(org_plain))
    create(:agent_claude_credential, organization:)

    get path, headers: { "Authorization" => "Bearer #{org_plain}" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a request without a token" do
    get path

    expect(response).to have_http_status(:unauthorized)
  end
end
