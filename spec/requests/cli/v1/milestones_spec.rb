# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Milestones", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro che VEDE il progetto (project_membership) ma senza projects.edit → testa il 403.
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  it "senza bearer → 401" do
    get "/cli/v1/projects/#{project.id}/milestones"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "→ 200 con le milestone del progetto e meta di paginazione" do
      milestone = create(:milestone, project:)

      get "/cli/v1/projects/#{project.id}/milestones", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |m| m["id"] }
      expect(ids).to include(milestone.id)
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "progetto di un'altra org → 404 (anti-BOLA, set_project!)" do
      other = create(:milestone) # progetto/org propri del factory

      get "/cli/v1/projects/#{other.project_id}/milestones", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET show" do
    it "→ 200 con id della milestone" do
      milestone = create(:milestone, project:)

      get "/cli/v1/projects/#{project.id}/milestones/#{milestone.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["id"]).to eq(milestone.id)
    end

    it "milestone di un altro progetto della stessa org → 404 (scope progetto)" do
      other_project = create(:project, organization:)
      other_milestone = create(:milestone, project: other_project)

      get "/cli/v1/projects/#{project.id}/milestones/#{other_milestone.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create (gate projects.edit)" do
    it "owner → 201, crea la milestone con created_by" do
      expect do
        post "/cli/v1/projects/#{project.id}/milestones", headers: headers,
                                                          params: { code: "v2", label: "v2.0", color: "indigo" }
      end.to change(Projects::Milestone, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["code"]).to eq("v2")
      expect(Projects::Milestone.find(data["id"]).created_by).to eq(account)
    end

    it "code assente → 422 R422-MILESTONE-001 con details" do
      post "/cli/v1/projects/#{project.id}/milestones", headers: headers,
                                                        params: { code: "", label: "v2.0", color: "indigo" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-MILESTONE-001")
      expect(response.parsed_body["error"]["details"]).to have_key("code")
    end

    it "membro che vede il progetto ma senza projects.edit → 403" do
      expect do
        post "/cli/v1/projects/#{project.id}/milestones", headers: member_headers,
                                                          params: { code: "v2", label: "v2.0", color: "indigo" }
      end.not_to change(Projects::Milestone, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "membro senza projects.edit → update 403 (guard)" do
      m = create(:milestone, project:)
      put "/cli/v1/projects/#{project.id}/milestones/#{m.id}", headers: member_headers, params: { label: "X" }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "membro senza projects.edit → destroy 403 (guard)" do
      m = create(:milestone, project:)
      delete "/cli/v1/projects/#{project.id}/milestones/#{m.id}", headers: member_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PUT update (gate projects.edit)" do
    let!(:milestone) { create(:milestone, project:, label: "Old") }

    it "owner aggiorna label → 200 + dato nuovo" do
      put "/cli/v1/projects/#{project.id}/milestones/#{milestone.id}", headers: headers,
                                                                       params: { label: "New" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["label"]).to eq("New")
      expect(milestone.reload.label).to eq("New")
    end

    it "validazione fallita (label vuoto) → 422 R422-MILESTONE-001" do
      put "/cli/v1/projects/#{project.id}/milestones/#{milestone.id}", headers: headers, params: { label: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-MILESTONE-001")
    end
  end

  describe "DELETE destroy (gate projects.edit)" do
    let!(:milestone) { create(:milestone, project:) }

    it "owner elimina → 204 e milestone rimossa" do
      delete "/cli/v1/projects/#{project.id}/milestones/#{milestone.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Projects::Milestone.exists?(milestone.id)).to be(false)
    end
  end
end
