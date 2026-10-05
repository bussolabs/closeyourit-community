# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::AgentHost::SkillManifests", type: :request do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:plain) { "cyi_ah_plain_secret_value" }
  let!(:host_token) { create(:agent_host_token, host:, token_digest: Digest::SHA256.hexdigest(plain)) }

  it "restituisce il bundle skill pinnato per un token host valido" do
    create(:agent_skill_bundle, organization:, repo: "bussolabs/closeyourit-skills", ref: "v0.1.0", version: "0.1.0", digest: "a" * 40)

    get "/api/v1/agent_host/skill_manifest", headers: { "Authorization" => "Bearer #{plain}" }

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data).to include(
      "version" => "0.1.0",
      "digest" => "a" * 40,
      "repo" => "bussolabs/closeyourit-skills",
      "ref" => "v0.1.0"
    )
  end

  it "rifiuta la richiesta senza header di autorizzazione" do
    get "/api/v1/agent_host/skill_manifest"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]["code"]).to eq("R401-AGENT-001")
  end

  it "rifiuta un token organization (cyi_a_) che non è un token host" do
    org_plain = "cyi_a_org_secret_value"
    create(:agent_token, organization:, token_digest: Digest::SHA256.hexdigest(org_plain))

    get "/api/v1/agent_host/skill_manifest", headers: { "Authorization" => "Bearer #{org_plain}" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "ritorna 404 quando l'org non ha un bundle pinnato (l'host resta in prompt-mode)" do
    get "/api/v1/agent_host/skill_manifest", headers: { "Authorization" => "Bearer #{plain}" }

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body["error"]["code"]).to eq("R404-AGENT-004")
  end

  it "non espone il bundle di un'altra organizzazione (isolamento tenant)" do
    create(:agent_skill_bundle, organization: create(:organization))

    get "/api/v1/agent_host/skill_manifest", headers: { "Authorization" => "Bearer #{plain}" }

    expect(response).to have_http_status(:not_found)
  end
end
