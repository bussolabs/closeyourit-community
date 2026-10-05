# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Ideas::Cases", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:outsider) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:idea) { create(:idea, organization: org, project: project) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: outsider, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST create" do
    it "non autenticato → redirect login" do
      post member_idea_cases_path(idea), params: { title: "x" }
      expect(response).to redirect_to(login_path)
    end

    it "owner (ideas.edit) aggiunge il case → cases_count +1" do
      sign_in(owner)
      expect do
        post member_idea_cases_path(idea), params: { title: "Onboarding", description: "Nuovo cliente" }
      end.to change { idea.reload.cases_count }.by(1)
      expect(response).to redirect_to(member_idea_path(idea))
    end

    it "l'autore dell'idea aggiunge il case (bypass permessi)" do
      author = idea.author
      create(:project_membership, account: author, project: project)
      sign_in(author)
      expect do
        post member_idea_cases_path(idea), params: { title: "Da autore" }
      end.to change { idea.reload.cases_count }.by(1)
    end

    it "membro con accesso ma senza ideas.edit (non autore) → negato, nessun case" do
      sign_in(member)
      expect do
        post member_idea_cases_path(idea), params: { title: "Hack" }
      end.not_to change(Ideas::Case, :count)
      expect(response).to have_http_status(:redirect)
    end

    it "titolo vuoto → nessun case, redirect con alert" do
      sign_in(owner)
      expect do
        post member_idea_cases_path(idea), params: { title: "  " }
      end.not_to change(Ideas::Case, :count)
      expect(response).to redirect_to(member_idea_path(idea))
      expect(flash[:alert]).to be_present
    end

    it "idea congelata → nessun case (R422-IDEA-002 dal service)" do
      frozen = create(:idea, :archived, organization: org, project: project)
      sign_in(owner)
      expect do
        post member_idea_cases_path(frozen), params: { title: "tardi" }
      end.not_to change(Ideas::Case, :count)
      expect(flash[:alert]).to be_present
    end

    it "membro senza accesso al progetto → 404 (BOLA)" do
      sign_in(outsider)
      post member_idea_cases_path(idea), params: { title: "x" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update" do
    let!(:idea_case) { create(:idea_case, idea: idea, title: "Vecchio") }

    it "owner modifica il case" do
      sign_in(owner)
      patch member_idea_case_path(idea, idea_case), params: { title: "Nuovo" }
      expect(idea_case.reload.title).to eq("Nuovo")
      expect(response).to redirect_to(member_idea_path(idea))
    end

    it "membro senza ideas.edit → negato, case invariato" do
      sign_in(member)
      patch member_idea_case_path(idea, idea_case), params: { title: "Hack" }
      expect(idea_case.reload.title).to eq("Vecchio")
      expect(response).to have_http_status(:redirect)
    end
  end

  describe "DELETE destroy" do
    let!(:idea_case) { create(:idea_case, idea: idea) }

    it "owner elimina il case" do
      sign_in(owner)
      expect { delete member_idea_case_path(idea, idea_case) }.to change(Ideas::Case, :count).by(-1)
    end

    it "membro senza ideas.edit → il case resta" do
      sign_in(member)
      expect { delete member_idea_case_path(idea, idea_case) }.not_to change(Ideas::Case, :count)
      expect(response).to have_http_status(:redirect)
    end

    it "idea congelata → il case resta (R422-IDEA-002)" do
      idea.update!(status: :archived)
      sign_in(owner)
      expect { delete member_idea_case_path(idea, idea_case) }.not_to change(Ideas::Case, :count)
      expect(flash[:alert]).to be_present
    end
  end
end
