# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets::Comments", type: :request do
  let(:org) { create(:organization) }
  let(:admin) { create(:account) }
  let(:member) { create(:account) }
  let(:customer) { create(:account) }
  let(:outsider) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  before do
    create(:membership, account: admin, organization: org, role: :admin)
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: customer, organization: org, role: :customer)
    create(:membership, account: outsider, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    create(:project_membership, account: customer, project: project)
    # outsider: membro dell'org ma SENZA accesso al progetto → non vede il ticket (scoping Fase E).
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST create" do
    it "non autenticato → redirect login" do
      post member_ticket_comments_path(ticket), params: { body: "hi" }
      expect(response).to redirect_to(login_path)
    end

    it "membro assegnato aggiunge un commento (autore = membro)" do
      sign_in(member)
      expect do
        post member_ticket_comments_path(ticket), params: { body: "Confermo il bug" }
      end.to change(Ticketing::Comment, :count).by(1)
      comment = Ticketing::Comment.last
      expect(comment.author).to eq(member)
      expect(comment.ticket).to eq(ticket)
      expect(response).to redirect_to(member_ticket_path(ticket, tab: "discussion"))
    end

    it "oltre i 240 caratteri: il flash NOMINA il tetto invece del messaggio generico" do
      sign_in(member)
      long = "x" * (Ticketing::Constants::COMMENT_MAX_CHARS + 1)

      expect do
        post member_ticket_comments_path(ticket), params: { body: long }
      end.not_to change(Ticketing::Comment, :count)

      expect(flash[:alert]).to include("240")
    end

    it "oltre i 240 caratteri: il testo scritto torna nel form, non si perde" do
      sign_in(member)
      long = "Testo che non deve sparire. #{"x" * 300}"

      post member_ticket_comments_path(ticket), params: { body: long }

      expect(flash[:comment_draft]).to eq(long)
      follow_redirect!
      expect(response.body).to include("Testo che non deve sparire.")
    end

    it "customer assegnato può commentare" do
      sign_in(customer)
      expect do
        post member_ticket_comments_path(ticket), params: { body: "Succede anche a me" }
      end.to change(Ticketing::Comment, :count).by(1)
      expect(Ticketing::Comment.last.author).to eq(customer)
    end

    it "body vuoto → nessun commento, redirect con alert" do
      sign_in(member)
      expect do
        post member_ticket_comments_path(ticket), params: { body: "   " }
      end.not_to change(Ticketing::Comment, :count)
      expect(response).to have_http_status(:redirect)
    end

    it "con allegato → file attaccato al commento" do
      sign_in(member)
      post member_ticket_comments_path(ticket), params: {
        body: "Vedi screenshot",
        files: [ fixture_file_upload("screenshot.png", "image/png") ]
      }
      expect(Ticketing::Comment.last.files).to be_attached
    end

    it "membro NON assegnato (non vede il ticket) → 404 (anti-BOLA)" do
      sign_in(outsider)
      expect do
        post member_ticket_comments_path(ticket), params: { body: "intruso" }
      end.not_to change(Ticketing::Comment, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "fa partire il broadcast realtime della discussione sullo stream del ticket" do
      sign_in(member)
      expect do
        post member_ticket_comments_path(ticket), params: { body: "live via request" }
      end.to have_broadcasted_to(Realtime::Streams.ticket(ticket)).at_least(:once)
    end
  end

  describe "DELETE destroy" do
    it "l'autore elimina il proprio commento" do
      sign_in(member)
      comment = create(:ticket_comment, ticket: ticket, author: member)
      expect do
        delete member_ticket_comment_path(ticket, comment)
      end.to change(Ticketing::Comment, :count).by(-1)
      expect(response).to redirect_to(member_ticket_path(ticket, tab: "discussion"))
    end

    it "un membro col permesso tickets.comment.delete_any elimina il commento di un altro" do
      manager = create(:account)
      create(:membership, account: manager, organization: org, role: :member)
      create(:project_membership, account: manager, project: project)
      role = create(:role, organization: org)
      create(:role_permission, role: role, permission_key: "tickets.comment.delete_any")
      create(:account_role, account: manager, organization: org, role: role)
      comment = create(:ticket_comment, ticket: ticket, author: member)
      sign_in(manager)
      expect do
        delete member_ticket_comment_path(ticket, comment), params: { confirm: "1" }
      end.to change(Ticketing::Comment, :count).by(-1)
    end

    it "owner elimina il commento di un altro" do
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :owner)
      comment = create(:ticket_comment, ticket: ticket, author: member)
      sign_in(owner)
      expect do
        delete member_ticket_comment_path(ticket, comment), params: { confirm: "1" }
      end.to change(Ticketing::Comment, :count).by(-1)
    end

    it "un altro membro non-admin non può eliminare il commento altrui" do
      author_member = create(:account)
      create(:membership, account: author_member, organization: org, role: :member)
      create(:project_membership, account: author_member, project: project)
      comment = create(:ticket_comment, ticket: ticket, author: author_member)

      sign_in(member)
      expect do
        delete member_ticket_comment_path(ticket, comment)
      end.not_to change(Ticketing::Comment, :count)
    end
  end
end
