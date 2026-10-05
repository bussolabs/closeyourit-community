# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Agents::SkillBundle", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:pin_params) { { repo: "bussolabs/closeyourit-skills", ref: "v0.1.0", version: "0.1.0", digest: "a1b2c3d" } }

  it "senza bearer → 401" do
    get "/cli/v1/agents/skill_bundle"

    expect(response).to have_http_status(:unauthorized)
  end

  context "membro senza agents.manage" do
    before { create(:membership, account:, organization:, role: :member) }

    it "update → 403 (serve agents.manage)" do
      put "/cli/v1/agents/skill_bundle", params: pin_params, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(organization.reload.skill_bundle).to be_nil
    end
  end

  context "owner (ha agents.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "show senza pin → 404 R404-AGENT-004" do
      get "/cli/v1/agents/skill_bundle", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("R404-AGENT-004")
    end

    it "update crea il pin → 200 coi 4 valori, resta un solo record" do
      expect { put "/cli/v1/agents/skill_bundle?confirm=1", params: pin_params, headers: headers }
        .to change { organization.reload.skill_bundle }.from(nil)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include(
        "repo" => "bussolabs/closeyourit-skills", "ref" => "v0.1.0", "version" => "0.1.0", "digest" => "a1b2c3d"
      )
      expect(::Agents::SkillBundle.where(organization:).count).to eq(1)
    end

    it "update è idempotente: un secondo PUT aggiorna lo stesso record (mai duplicati)" do
      put "/cli/v1/agents/skill_bundle?confirm=1", params: pin_params, headers: headers
      put "/cli/v1/agents/skill_bundle?confirm=1",
          params: pin_params.merge(ref: "v0.2.0", version: "0.2.0", digest: "ffffff0"), headers: headers

      expect(response).to have_http_status(:ok)
      expect(organization.reload.skill_bundle.version).to eq("0.2.0")
      expect(::Agents::SkillBundle.where(organization:).count).to eq(1)
    end

    it "update con repo non valido → 422 R422-AGENT-006 senza persistere" do
      put "/cli/v1/agents/skill_bundle?confirm=1", params: pin_params.merge(repo: "non-un-repo"), headers: headers

      expect(response).to have_http_status(422)
      expect(response.body).to include("R422-AGENT-006")
      expect(organization.reload.skill_bundle).to be_nil
    end

    it "show dopo il pin → 200 coi valori correnti" do
      create(:agent_skill_bundle, organization:, ref: "v0.3.0", version: "0.3.0", digest: "c" * 12)

      get "/cli/v1/agents/skill_bundle", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include("version" => "0.3.0", "ref" => "v0.3.0")
    end

    it "update anti-BOLA: non tocca il bundle di un'altra org" do
      other = create(:agent_skill_bundle)

      put "/cli/v1/agents/skill_bundle?confirm=1", params: pin_params, headers: headers

      expect(response).to have_http_status(:ok)
      expect(other.reload.version).to eq("1.0.0")
      expect(organization.reload.skill_bundle.id).not_to eq(other.id)
    end

    it "update rifiuta un downgrade → 409 R409-AGENT-002 e il pin non regredisce" do
      create(:agent_skill_bundle, organization:, ref: "v0.2.0", version: "0.2.0", digest: "b" * 12)

      put "/cli/v1/agents/skill_bundle?confirm=1",
          params: pin_params.merge(ref: "v0.1.0", version: "0.1.0"), headers: headers

      expect(response).to have_http_status(:conflict)
      expect(response.body).to include("R409-AGENT-002")
      expect(organization.reload.skill_bundle.version).to eq("0.2.0")
    end

    it "update con force: true applica il downgrade (rollback intenzionale) → 200" do
      create(:agent_skill_bundle, organization:, ref: "v0.2.0", version: "0.2.0", digest: "b" * 12)

      put "/cli/v1/agents/skill_bundle?confirm=1",
          params: pin_params.merge(ref: "v0.1.0", version: "0.1.0", force: true), headers: headers

      expect(response).to have_http_status(:ok)
      expect(organization.reload.skill_bundle.version).to eq("0.1.0")
    end

    it "update con force: false (param stringa) NON bypassa: resta monotonico → 409" do
      create(:agent_skill_bundle, organization:, ref: "v0.2.0", version: "0.2.0", digest: "b" * 12)

      put "/cli/v1/agents/skill_bundle?confirm=1",
          params: pin_params.merge(ref: "v0.1.0", version: "0.1.0", force: false), headers: headers

      expect(response).to have_http_status(:conflict)
      expect(response.body).to include("R409-AGENT-002")
      expect(organization.reload.skill_bundle.version).to eq("0.2.0")
    end
  end
end
