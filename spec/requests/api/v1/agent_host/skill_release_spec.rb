# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::AgentHost::SkillRelease", type: :request do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:plain) { "cyi_ah_plain_secret_value" }
  let(:host_headers) { { "Authorization" => "Bearer #{plain}" } }

  before { create(:agent_host_token, host:, token_digest: Digest::SHA256.hexdigest(plain)) }

  it "gives the host the version its organization must run" do
    create(:skill_release, version: "1.4.0")

    get "/api/v1/agent_host/skill_release", headers: host_headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]).to include("version" => "1.4.0", "pinned" => false)
  end

  it "answers 404 R404-AGENT-009 when nothing is available" do
    get "/api/v1/agent_host/skill_release", headers: host_headers

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("R404-AGENT-009")
  end

  it "refuses requests without the host token" do
    get "/api/v1/agent_host/skill_release"

    expect(response).to have_http_status(:unauthorized)
  end
end
