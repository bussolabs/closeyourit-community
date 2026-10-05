# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Projects::EnvironmentCapabilities (override)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  def put_capabilities(env_ref = environment.code, target = project, **params)
    put "/cli/v1/projects/#{target.id}/environments/#{env_ref}/capabilities",
        headers: { "Authorization" => "Bearer #{token_for(account)}" }, params: params
  end

  def link
    project.project_environments.find_by(environment_id: environment.id)
  end

  context "owner (projects.edit)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "imposta gli override per code → 200 + override e risolto nell'envelope" do
      put_capabilities(environment.code, uptime: "off", servers: "inherit")

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["data"]
      expect(body["uptime_override"]).to be(false)
      expect(body["uptime_enabled"]).to be(false) # risolto = override
      expect(body["servers_override"]).to be_nil  # inherit
      expect(link[:uptime_enabled]).to be(false)
    end

    it "risolve l'ambiente per UUID" do
      put_capabilities(environment.id, secrets: "off")

      expect(response).to have_http_status(:ok)
      expect(link[:secrets_enabled]).to be(false)
    end

    it "tocca solo le capability fornite" do
      put_capabilities(environment.code, servers: "on")

      expect(link[:servers_enabled]).to be(true)
      expect(link[:uptime_enabled]).to be_nil
      expect(link[:secrets_enabled]).to be_nil
    end

    it "imposta la capability approval (CYRA-138): colonna approval_required, non approval_enabled" do
      put_capabilities(environment.code, capability: "approval", value: "on")

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["data"]
      expect(link[:approval_required]).to be(true)
      # Il serializer CLI non espone (ancora) approval_override/approval_enabled: la envelope resta
      # quella delle 3 capability storiche finché il canale CLI dei change request non lo richiede.
      expect(body).to include("servers_override", "uptime_override", "secrets_override")
    end

    it "ambiente non dichiarato dal progetto → 404" do
      undeclared = create(:environment, organization:, code: "qa")

      put_capabilities(undeclared.code, uptime: "off")

      expect(response).to have_http_status(:not_found)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      other = create(:project, organization: create(:organization))

      put_capabilities(environment.code, other, uptime: "off")

      expect(response).to have_http_status(:not_found)
    end
  end

  context "membro senza projects.edit" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end

    it "PUT → 403 R403-CLIAUTH-002" do
      environment # forza la dichiarazione dell'ambiente

      put_capabilities(environment.code, uptime: "off")

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  it "senza token → 401" do
    put "/cli/v1/projects/#{project.id}/environments/#{environment.code}/capabilities", params: { uptime: "off" }

    expect(response).to have_http_status(:unauthorized)
  end
end
