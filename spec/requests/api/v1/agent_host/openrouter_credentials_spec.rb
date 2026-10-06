# frozen_string_literal: true

require "rails_helper"

# CYAU-228 — the OpenRouter key OpenCode reviews with, lent by the organization.
RSpec.describe "Api::V1::AgentHost::OpenrouterCredentials", type: :request do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:plain) { "cyi_ah_plain_secret_value" }
  let(:path) { "/api/v1/agent_host/openrouter_credential" }
  let(:headers) { { "Authorization" => "Bearer #{plain}" } }

  before { create(:agent_host_token, host:, token_digest: Digest::SHA256.hexdigest(plain)) }

  it "serves the organization's key to a certified host" do
    create(:agent_openrouter_credential, organization:, token: "sk-or-v1-served")

    get path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body["data"]).to eq("env" => "OPENROUTER_API_KEY", "token" => "sk-or-v1-served")
  end

  it "answers 404 when the organization has no key" do
    get path, headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body["error"]["code"]).to eq("R404-AGENT-006")
  end

  it "refuses an uncertified host" do
    host.update!(certified_at: nil)
    create(:agent_openrouter_credential, organization:)

    get path, headers: headers

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]["code"]).to eq("R403-AGENT-008")
  end

  it "refuses a request without a host token" do
    get path

    expect(response).to have_http_status(:unauthorized)
  end
end
