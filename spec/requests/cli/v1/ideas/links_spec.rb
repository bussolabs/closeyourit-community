# frozen_string_literal: true

require "rails_helper"

# CYRA-845 — collegamenti fra idee via CLI.
RSpec.describe "Cli::V1::Ideas::Links", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:) }
  let(:other) { create(:idea, organization:, project:, title: "Idea cugina") }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  def links_path(target = idea)
    "/cli/v1/projects/#{project.id}/ideas/#{target.id}/links"
  end

  it "senza bearer → 401" do
    post links_path, params: { target_id: other.id }
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "create related → 201 e il serializer elenca l'idea collegata" do
      post links_path, params: { target_id: other.id }, headers: headers

      expect(response).to have_http_status(:created)
      related = response.parsed_body.dig("data", "related_ideas")
      expect(related).to contain_exactly(a_hash_including("id" => other.id, "title" => "Idea cugina", "status" => "open"))
    end

    it "create evolution → 201, parent valorizzato" do
      post links_path, params: { target_id: other.id, kind: "evolution" }, headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "parent")).to include("id" => other.id)
    end

    it "kind sconosciuto → 422 R422-IDEA-006" do
      post links_path, params: { target_id: other.id, kind: "cugina" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-006")
    end

    it "target di un altro progetto → 404 R404-IDEA-002 (anti-BOLA)" do
      foreign = create(:idea, organization:)
      post links_path, params: { target_id: foreign.id }, headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-IDEA-002")
    end

    it "destroy → 204, da qualunque lato" do
      create(:idea_link, source: other, target: idea)
      expect do
        delete "#{links_path}/#{other.id}", headers: headers
      end.to change(Ideas::Link, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "ideas create con evolves_id, monetization e risks → 201 e show li rende" do
      post "/cli/v1/projects/#{project.id}/ideas",
           params: { title: "Tavoli", problem: "Con chi?", monetization: "Boost", risks: "Moderazione",
                     evolves_id: other.id }, headers: headers
      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data).to include("monetization" => "Boost", "risks" => "Moderazione")
      expect(data["parent"]).to include("id" => other.id)

      get "/cli/v1/projects/#{project.id}/ideas/#{other.id}", headers: headers
      expect(response.parsed_body.dig("data", "evolutions")).to contain_exactly(a_hash_including("title" => "Tavoli"))
    end

    it "index → nessun N+1 con parent, evoluzioni e collegate" do
      # Fixture bulk: le validazioni del link (una coppia alla volta) non sono N+1 di produzione.
      allow_n_plus_one do
        base = create(:idea, organization:, project:)
        3.times do
          child = create(:idea, organization:, project:)
          create(:idea_link, :evolution, source: child, target: base)
          create(:idea_link, source: create(:idea, organization:, project:), target: child)
        end
      end
      get "/cli/v1/projects/#{project.id}/ideas", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end

  context "membro non autore senza ideas.edit" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end

    it "create → 403" do
      post links_path, params: { target_id: other.id },
                       headers: { "Authorization" => "Bearer #{token_for(account)}" }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
