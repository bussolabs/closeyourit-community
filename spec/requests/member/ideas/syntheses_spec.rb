# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Ideas::Syntheses", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:author) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:idea) { create(:idea, organization: org, project: project, author: author) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: author, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    create(:project_membership, account: author, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST create" do
    it "non autenticato → redirect login" do
      post member_idea_synthesis_path(idea)
      expect(response).to redirect_to(login_path)
    end

    it "l'autore accoda la sintesi → 202 con request_id (kind idea_synthesize)" do
      sign_in(author)
      expect { post member_idea_synthesis_path(idea) }.to change(Ai::Request, :count).by(1)

      expect(response).to have_http_status(:accepted)
      body = response.parsed_body
      expect(body["data"]["request_id"]).to be_present
      expect(Ai::Request.last).to have_attributes(kind: "idea_synthesize", account: author)
      expect(Ai::Request.last.args).to eq("idea_id" => idea.id)
    end

    it "owner (ideas.convert implicito) accoda la sintesi per un'idea altrui" do
      sign_in(owner)
      post member_idea_synthesis_path(idea)
      expect(response).to have_http_status(:accepted)
    end

    it "membro NON autore senza ideas.convert → 403 R403-IDEA-001" do
      sign_in(member)
      expect { post member_idea_synthesis_path(idea) }.not_to change(Ai::Request, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-IDEA-001")
    end

    it "idea già convertita → 422 R422-IDEA-003" do
      converted = create(:idea, :converted, organization: org, project: project, author: author)
      sign_in(author)
      post member_idea_synthesis_path(converted)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-003")
    end

    it "idea archiviata → 422 R422-IDEA-002" do
      archived = create(:idea, :archived, organization: org, project: project, author: author)
      sign_in(author)
      post member_idea_synthesis_path(archived)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-002")
    end

    it "membro senza accesso al progetto → 404 (BOLA)" do
      stranger = create(:account)
      create(:membership, account: stranger, organization: org, role: :member)
      sign_in(stranger)
      post member_idea_synthesis_path(idea)
      expect(response).to have_http_status(:not_found)
    end
  end
end
