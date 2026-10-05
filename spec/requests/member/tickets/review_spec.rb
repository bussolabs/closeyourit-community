# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets::Review", type: :request do
  let(:org) { create(:organization) }
  let(:admin) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:in_review) { create(:ticket_status, :in_review, organization: org, position: 2) }
  let!(:in_progress) { create(:ticket_status, :in_progress, organization: org, position: 1) }
  let!(:resolved) { create(:ticket_status, :done, organization: org, position: 3) }
  let(:ticket) { create(:ticket, organization: org, project: project, status: in_review) }

  before do
    create(:membership, account: admin, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST /member/tickets/:ticket_id/review/rejection" do
    it "non autenticato → redirect login" do
      post member_ticket_review_rejection_path(ticket), params: { reason: "x" }
      expect(response).to redirect_to(login_path)
    end

    it "owner respinge: status torna in progress, commento col motivo, redirect con notice" do
      sign_in(admin)
      post member_ticket_review_rejection_path(ticket), params: { reason: "Manca il test" }
      expect(response).to have_http_status(:redirect)
      expect(flash[:notice]).to eq(I18n.t("member.tickets.review_rejected"))
      expect(ticket.reload.status).to eq(in_progress)
      expect(ticket.comments.last.body).to eq("Manca il test")
      expect(Ticketing::Event.last.action).to eq("review_rejected")
    end

    it "membro senza tickets.edit → redirect root (gate), status invariato" do
      sign_in(member)
      post member_ticket_review_rejection_path(ticket), params: { reason: "x" }
      expect(response).to redirect_to(root_path)
      expect(ticket.reload.status).to eq(in_review)
    end

    it "ticket non visibile → 404 (anti-BOLA)" do
      sign_in(admin)
      foreign = create(:ticket, organization: create(:organization))
      post member_ticket_review_rejection_path(foreign), params: { reason: "x" }
      expect(response).to have_http_status(:not_found)
    end

    it "ticket non in review → redirect con alert, status invariato" do
      sign_in(admin)
      working = create(:ticket, organization: org, project: project, status: in_progress)
      post member_ticket_review_rejection_path(working), params: { reason: "x" }
      expect(flash[:alert]).to eq(I18n.t("member.tickets.errors.not_in_review"))
      expect(working.reload.status).to eq(in_progress)
    end

    it "reason mancante → alert, status invariato, nessun commento" do
      sign_in(admin)
      post member_ticket_review_rejection_path(ticket), params: { reason: "   " }
      expect(flash[:alert]).to eq(I18n.t("member.tickets.errors.reason_required"))
      expect(ticket.reload.status).to eq(in_review)
      expect(ticket.comments).to be_empty
    end
  end

  describe "POST /member/tickets/:ticket_id/review/approval" do
    it "non autenticato → redirect login" do
      post member_ticket_review_approval_path(ticket)
      expect(response).to redirect_to(login_path)
    end

    it "owner approva: status va sul primo done, redirect con notice" do
      sign_in(admin)
      post member_ticket_review_approval_path(ticket)
      expect(flash[:notice]).to eq(I18n.t("member.tickets.review_approved"))
      expect(ticket.reload.status).to eq(resolved)
      expect(Ticketing::Event.last.action).to eq("review_approved")
    end

    it "membro senza tickets.edit → redirect root (gate), status invariato" do
      sign_in(member)
      post member_ticket_review_approval_path(ticket)
      expect(response).to redirect_to(root_path)
      expect(ticket.reload.status).to eq(in_review)
    end

    it "ticket non visibile → 404 (anti-BOLA)" do
      sign_in(admin)
      foreign = create(:ticket, organization: create(:organization))
      post member_ticket_review_approval_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "ticket non in review → redirect con alert, status invariato" do
      sign_in(admin)
      working = create(:ticket, organization: org, project: project, status: in_progress)
      post member_ticket_review_approval_path(working)
      expect(flash[:alert]).to eq(I18n.t("member.tickets.errors.not_in_review"))
      expect(working.reload.status).to eq(in_progress)
    end
  end
end
