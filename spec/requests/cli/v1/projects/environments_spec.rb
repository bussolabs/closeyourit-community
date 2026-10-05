# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Projects::Environments (dichiarazione)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  def put_environments(target = project, **params)
    put "/cli/v1/projects/#{target.id}/environments",
        headers: { "Authorization" => "Bearer #{token_for(account)}" }, params: params
  end

  context "owner (projects.edit)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "dichiara gli environment per code → 200 + envelope data" do
      create(:environment, organization:, code: "production")

      put_environments(codes: [ "production" ])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |e| e["code"] }).to include("production")
      expect(project.reload.environments.pluck(:code)).to include("production")
    end

    it "accetta environment_ids (UUID)" do
      dev = create(:environment, organization:, code: "development")

      put_environments(environment_ids: [ dev.id ])

      expect(response).to have_http_status(:ok)
      expect(project.reload.environments).to include(dev)
    end

    it "il SET sostituisce le dichiarazioni esistenti (non additivo)" do
      prod = create(:environment, organization:, code: "production")
      stg  = create(:environment, organization:, code: "staging")
      project.environments << prod

      put_environments(codes: [ "staging" ])

      expect(project.reload.environments).to contain_exactly(stg)
    end

    it "ignora codes ignoti e blank (scoping org)" do
      create(:environment, organization:, code: "production")

      put_environments(codes: [ "production", "", "nonexistent" ])

      expect(project.reload.environments.pluck(:code)).to contain_exactly("production")
    end

    it "environment di un'altra org non entra (scoping tenant)" do
      foreign = create(:environment, organization: create(:organization), code: "production")

      put_environments(environment_ids: [ foreign.id ])

      expect(project.reload.environments).to be_empty
    end

    it "progetto di un'altra organizzazione → 404 (anti-BOLA)" do
      other = create(:project, organization: create(:organization))

      put_environments(other, codes: [ "production" ])

      expect(response).to have_http_status(:not_found)
    end
  end

  context "membro senza projects.edit (vede il progetto ma non può)" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end

    it "PUT → 403 R403-CLIAUTH-002" do
      create(:environment, organization:, code: "production")

      put_environments(codes: [ "production" ])

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  it "senza token → 401" do
    create(:environment, organization:, code: "production")

    put "/cli/v1/projects/#{project.id}/environments", params: { codes: [ "production" ] }

    expect(response).to have_http_status(:unauthorized)
  end
end
