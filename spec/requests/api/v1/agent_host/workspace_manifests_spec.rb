# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::AgentHost::WorkspaceManifests", type: :request do
  let(:organization) { create(:organization) }
  # Host-first (CYAU-100): il manifest è per-host e deriva dalla ProjectScope del suo service account.
  let(:service_account) do
    create(:account, :service).tap { |account| create(:project_membership, account:, project:) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:plain) { "cyi_ah_plain_secret_value" }
  let!(:host_token) { create(:agent_host_token, host:, token_digest: Digest::SHA256.hexdigest(plain)) }

  let(:project) { create(:project, organization:, key: "CYRA") }
  let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails") }

  it "restituisce il manifest della workspace per un token host valido" do
    get "/api/v1/agent_host/workspace_manifest", headers: { "Authorization" => "Bearer #{plain}" }

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data["version"]).to eq(1)
    expect(data["digest"]).to be_present
    expect(data["workspace_root_hint"]).to eq("Lavoro/Github/Personale")

    entry = data["repositories"].sole
    expect(entry).to include(
      "project_key" => "CYRA",
      "repo" => "bussolabs/closeyourit-rails",
      "default_branch" => "main",
      "path" => "closeyourit-rails"
    )
  end

  it "rifiuta la richiesta senza header di autorizzazione" do
    get "/api/v1/agent_host/workspace_manifest"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]["code"]).to eq("R401-AGENT-001")
  end

  it "rifiuta un token organization (cyi_a_) che non è un token host" do
    org_plain = "cyi_a_org_secret_value"
    create(:agent_token, organization:, token_digest: Digest::SHA256.hexdigest(org_plain))

    get "/api/v1/agent_host/workspace_manifest", headers: { "Authorization" => "Bearer #{org_plain}" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "rifiuta con 403 il token di un host storico non Linux" do
    host.update_column(:platform, "darwin")

    get "/api/v1/agent_host/workspace_manifest", headers: { "Authorization" => "Bearer #{plain}" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-AGENT-007")
  end
end
