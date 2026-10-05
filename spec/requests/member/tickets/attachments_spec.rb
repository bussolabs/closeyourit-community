# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets::Attachments", type: :request do
  let(:org) { create(:organization) }
  let(:admin) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  before do
    create(:membership, account: admin, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST create" do
    it "admin allega un file valido al ticket" do
      sign_in(admin)
      post member_ticket_attachments_path(ticket), params: {
        files: [ fixture_file_upload("screenshot.png", "image/png") ]
      }
      expect(ticket.reload.files).to be_attached
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "membro non-manager → negato, nessun allegato" do
      sign_in(member)
      post member_ticket_attachments_path(ticket), params: {
        files: [ fixture_file_upload("screenshot.png", "image/png") ]
      }
      expect(ticket.reload.files).not_to be_attached
      expect(response).to redirect_to(root_path)
    end

    it "tipo non ammesso → rifiutato, nessun allegato" do
      sign_in(admin)
      post member_ticket_attachments_path(ticket), params: {
        files: [ fixture_file_upload("diagram.svg", "image/svg+xml") ]
      }
      expect(ticket.reload.files).not_to be_attached
      expect(response).to have_http_status(:redirect)
    end

    it "senza file → nessun allegato, redirect con alert" do
      sign_in(admin)
      post member_ticket_attachments_path(ticket), params: {}
      expect(ticket.reload.files).not_to be_attached
      expect(response).to have_http_status(:redirect)
    end

    it "content-type spoofato (svg dichiarato image/png) → rifiutato (sniff server-side)" do
      sign_in(admin)
      post member_ticket_attachments_path(ticket), params: {
        files: [ fixture_file_upload("diagram.svg", "image/png") ]
      }
      expect(ticket.reload.files).not_to be_attached
      expect(response).to have_http_status(:redirect)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      sign_in(admin)
      foreign = create(:ticket, organization: create(:organization))
      post member_ticket_attachments_path(foreign), params: {
        files: [ fixture_file_upload("screenshot.png", "image/png") ]
      }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    it "admin rimuove un allegato del ticket" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = ticket.files.first
      sign_in(admin)
      expect do
        delete member_ticket_attachment_path(ticket, attachment)
      end.to change { ticket.reload.files.count }.by(-1)
    end

    it "membro non-manager non può rimuovere allegati del ticket" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = ticket.files.first
      sign_in(member)
      delete member_ticket_attachment_path(ticket, attachment)
      expect(ticket.reload.files).to be_attached
    end
  end
end
