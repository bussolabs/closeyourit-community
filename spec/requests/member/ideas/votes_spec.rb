# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Ideas::Votes", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:outsider) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:idea) { create(:idea, organization: org, project: project) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: outsider, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "PUT update (upvote)" do
    it "non autenticato → redirect login" do
      put member_idea_vote_path(idea)
      expect(response).to redirect_to(login_path)
    end

    it "membro con accesso vota → votes_count +1" do
      sign_in(member)
      expect { put member_idea_vote_path(idea) }.to change { idea.reload.votes_count }.by(1)
      expect(response).to redirect_to(member_idea_path(idea))
    end

    it "voto idempotente: doppio PUT = un solo voto" do
      sign_in(member)
      put member_idea_vote_path(idea)
      expect { put member_idea_vote_path(idea) }.not_to(change { idea.reload.votes_count })
      expect(idea.reload.votes_count).to eq(1)
    end

    it "membro senza accesso al progetto → 404 (BOLA)" do
      sign_in(outsider)
      put member_idea_vote_path(idea)
      expect(response).to have_http_status(:not_found)
    end

    it "idea archiviata (congelata) → nessun voto" do
      frozen = create(:idea, :archived, organization: org, project: project)
      sign_in(member)
      expect { put member_idea_vote_path(frozen) }.not_to(change { frozen.reload.votes_count })
    end

    it "idea convertita (congelata) → nessun voto" do
      converted = create(:idea, :converted, organization: org, project: project)
      sign_in(member)
      expect { put member_idea_vote_path(converted) }.not_to(change { converted.reload.votes_count })
    end
  end

  describe "DELETE destroy (unvote)" do
    it "rimuove il voto dell'account (idempotente)" do
      sign_in(member)
      put member_idea_vote_path(idea)
      expect { delete member_idea_vote_path(idea) }.to change { idea.reload.votes_count }.by(-1)
      expect { delete member_idea_vote_path(idea) }.not_to(change { idea.reload.votes_count })
    end

    it "rimuove SOLO il voto dell'account corrente" do
      other = create(:account)
      create(:membership, account: other, organization: org, role: :member)
      create(:idea_vote, idea: idea, account: other)

      sign_in(member)
      put member_idea_vote_path(idea)
      delete member_idea_vote_path(idea)

      expect(idea.reload.votes_count).to eq(1)
      expect(idea.votes.first.account).to eq(other)
    end
  end
end
