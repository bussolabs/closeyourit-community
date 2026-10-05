# frozen_string_literal: true

require "rails_helper"

# Pendant di projects/environments_spec.rb: dichiarazione delle piattaforme del progetto da CLI
# (gap emerso registrando i monitor uptime: senza piattaforma web/server il monitor è rifiutato).
RSpec.describe "Cli::V1::Projects::Platforms (dichiarazione)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  def put_platforms(target = project, **params)
    put "/cli/v1/projects/#{target.id}/platforms",
        headers: { "Authorization" => "Bearer #{token_for(account)}" }, params: params
  end

  context "owner (projects.edit)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "dichiara le piattaforme per code → 200 + envelope data" do
      create(:platform, organization:, code: "web")

      put_platforms(codes: [ "web" ])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |p| p["code"] }).to include("web")
      expect(project.reload.platforms.pluck(:code)).to include("web")
    end

    it "accetta platform_ids (UUID)" do
      ios = create(:platform, organization:, code: "ios")

      put_platforms(platform_ids: [ ios.id ])

      expect(response).to have_http_status(:ok)
      expect(project.reload.platforms).to include(ios)
    end

    it "il SET sostituisce le dichiarazioni esistenti (non additivo)" do
      web = create(:platform, organization:, code: "web")
      ios = create(:platform, organization:, code: "ios")
      project.platforms << web

      put_platforms(codes: [ "ios" ])

      expect(project.reload.platforms).to contain_exactly(ios)
    end

    it "ignora codes ignoti e blank (scoping org)" do
      create(:platform, organization:, code: "web")

      put_platforms(codes: [ "web", "", "nonexistent" ])

      expect(project.reload.platforms.pluck(:code)).to contain_exactly("web")
    end

    it "piattaforma di un'altra org non entra (scoping tenant)" do
      foreign = create(:platform, organization: create(:organization), code: "web")

      put_platforms(platform_ids: [ foreign.id ])

      expect(project.reload.platforms).to be_empty
    end

    it "lista vuota → azzera le piattaforme dichiarate" do
      project.platforms << create(:platform, organization:, code: "web")

      put_platforms

      expect(response).to have_http_status(:ok)
      expect(project.reload.platforms).to be_empty
    end

    it "progetto di un'altra organizzazione → 404 (anti-BOLA)" do
      other = create(:project, organization: create(:organization))

      put_platforms(other, codes: [ "web" ])

      expect(response).to have_http_status(:not_found)
    end
  end

  context "member senza projects.edit" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end

    it "→ 403" do
      put_platforms(codes: [ "web" ])
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "senza token → 401" do
    put "/cli/v1/projects/#{project.id}/platforms", params: { codes: [ "web" ] }
    expect(response).to have_http_status(:unauthorized)
  end
end
