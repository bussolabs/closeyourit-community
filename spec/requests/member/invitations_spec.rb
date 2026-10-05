# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Invitations", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:owner_m) { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET new" do
    it "owner → 200" do
      sign_in(owner)
      get new_member_invitation_path
      expect(response).to have_http_status(:ok)
    end

    it "member semplice → redirect home" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      sign_in(member)
      get new_member_invitation_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST create" do
    it "owner invita: crea l'invito, accoda l'email, redirect ai membri" do
      sign_in(owner)
      expect do
        post member_invitations_path, params: { email: "new@example.com", role: "admin" }
      end.to have_enqueued_mail(Connections::InvitationsMailer, :invite)
      expect(response).to redirect_to(member_members_path)
      expect(org.invitations.pending.where(email: "new@example.com")).to exist
    end

    it "email già membro → 422 render new" do
      existing = create(:account, email: "dup@example.com")
      create(:membership, account: existing, organization: org, role: :member)
      sign_in(owner)
      post member_invitations_path, params: { email: "dup@example.com", role: "member" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST resend" do
    it "owner reinvia l'email" do
      invitation = org.invitations.create!(email: "p@example.com", role: :member)
      sign_in(owner)
      expect do
        post resend_member_invitation_path(invitation)
      end.to have_enqueued_mail(Connections::InvitationsMailer, :invite)
      expect(response).to redirect_to(member_members_path)
    end
  end

  describe "DELETE destroy" do
    it "owner revoca l'invito" do
      invitation = org.invitations.create!(email: "p@example.com", role: :member)
      sign_in(owner)
      expect { delete member_invitation_path(invitation) }.to change(Connections::Invitation, :count).by(-1)
      expect(response).to redirect_to(member_members_path)
    end

    it "BOLA: invito di un'altra org → 404" do
      other = create(:organization).invitations.create!(email: "x@example.com", role: :member)
      sign_in(owner)
      delete member_invitation_path(other)
      expect(response).to have_http_status(:not_found)
      expect(Connections::Invitation).to exist(other.id)
    end
  end
end
