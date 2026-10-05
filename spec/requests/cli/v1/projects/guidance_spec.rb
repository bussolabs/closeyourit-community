# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Projects::Guidance", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:group) { create(:group, organization:) }
  let(:project) { create(:project, organization:, group:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  describe "GET /cli/v1/projects/:project_id/guidance" do
    it "risponde 200 con references e procedures risolte dei tre livelli, con origine" do
      create(:guidance_reference, owner: organization, key: "org-repo", position: 0)
      create(:guidance_reference, :knowledge_base, owner: group, key: "group-doc", position: 1)
      create(:guidance_reference, :path, owner: project, key: "proj-path", position: 2)
      create(:guidance_procedure, owner: organization, key: "setup", content: "Installa le dipendenze")

      get "/cli/v1/projects/#{project.id}/guidance", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["references"].map { |r| r["key"] }).to eq(%w[org-repo group-doc proj-path])
      expect(data["references"].map { |r| r["level"] }).to eq(%w[organization group project])
      expect(data["procedures"].map { |p| p["key"] }).to eq(%w[setup])
      expect(data["procedures"].first["content"]).to eq("Installa le dipendenze")
    end

    it "riflette override (replace) e disable nel payload risolto" do
      create(:guidance_reference, owner: organization, key: "repo", location: "git@org")
      create(:guidance_reference, owner: project, key: "repo", location: "git@project")
      create(:guidance_reference, owner: organization, key: "legacy")
      create(:guidance_reference, :disabled, owner: project, key: "legacy")

      get "/cli/v1/projects/#{project.id}/guidance", headers: headers

      refs = response.parsed_body["data"]["references"]
      repo = refs.find { |r| r["key"] == "repo" }
      expect(repo["location"]).to eq("git@project")
      expect(repo["level"]).to eq("project")
      expect(refs.map { |r| r["key"] }).not_to include("legacy")
    end

    it "restituisce collezioni vuote se il progetto non ha guidance" do
      get "/cli/v1/projects/#{project.id}/guidance", headers: headers

      data = response.parsed_body["data"]
      expect(data["references"]).to eq([])
      expect(data["procedures"]).to eq([])
    end

    it "non mostra la guidance di un altro progetto/organizzazione (isolamento tenant)" do
      other_project = create(:project)
      create(:guidance_reference, owner: other_project, key: "altrui")

      get "/cli/v1/projects/#{project.id}/guidance", headers: headers

      expect(response.parsed_body["data"]["references"]).to eq([])
    end

    it "un progetto di un'altra org → 404 (anti-BOLA)" do
      other = create(:project)

      get "/cli/v1/projects/#{other.id}/guidance", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "senza token → 401" do
      get "/cli/v1/projects/#{project.id}/guidance"

      expect(response).to have_http_status(:unauthorized)
    end

    it "regge molti elementi con un numero costante di query (no N+1)" do
      allow_n_plus_one do
        create_list(:guidance_reference, 3, owner: organization)
        create_list(:guidance_procedure, 3, owner: project)
      end

      get "/cli/v1/projects/#{project.id}/guidance", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["references"].size).to eq(3)
      expect(response.parsed_body["data"]["procedures"].size).to eq(3)
    end
  end
end
