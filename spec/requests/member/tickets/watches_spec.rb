# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets::Watches", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:customer) { create(:account) }
  let(:outsider) { create(:account) }
  let(:other_org) { create(:organization) }
  let(:stranger) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: customer, organization: org, role: :customer)
    create(:membership, account: outsider, organization: org, role: :member)
    create(:membership, account: stranger, organization: other_org, role: :member)
    create(:project_membership, account: member, project: project)
    create(:project_membership, account: customer, project: project)
    # outsider: membro dell'org ma SENZA accesso al progetto → non vede il ticket (scoping Fase E).
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "PUT update (watch)" do
    it "non autenticato → redirect login" do
      put member_ticket_watch_path(ticket)
      expect(response).to redirect_to(login_path)
    end

    it "membro con accesso si iscrive → subscriptions +1" do
      sign_in(member)
      expect { put member_ticket_watch_path(ticket) }.to change { ticket.subscriptions.count }.by(1)
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "customer con accesso può iscriversi" do
      sign_in(customer)
      expect { put member_ticket_watch_path(ticket) }.to change { ticket.subscriptions.count }.by(1)
    end

    it "iscrizione idempotente: doppio PUT = una sola sottoscrizione" do
      sign_in(member)
      put member_ticket_watch_path(ticket)
      expect { put member_ticket_watch_path(ticket) }.not_to(change { ticket.subscriptions.count })
      expect(ticket.subscriptions.count).to eq(1)
    end

    it "ticket non visibile (membro org senza accesso al progetto) → 404" do
      sign_in(outsider)
      put member_ticket_watch_path(ticket)
      expect(response).to have_http_status(:not_found)
    end

    it "BOLA: account di un'altra org → 404" do
      sign_in(stranger)
      put member_ticket_watch_path(ticket)
      expect(response).to have_http_status(:not_found)
    end

    it "fa il replace realtime del contatore watcher sullo stream del ticket" do
      sign_in(member)
      expect do
        put member_ticket_watch_path(ticket)
      end.to have_broadcasted_to(Realtime::Streams.ticket(ticket))
    end
  end

  describe "DELETE destroy (unwatch)" do
    it "rimuove la sottoscrizione → subscriptions −1" do
      sign_in(member)
      put member_ticket_watch_path(ticket)
      expect { delete member_ticket_watch_path(ticket) }.to change { ticket.subscriptions.count }.by(-1)
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "rimozione idempotente: DELETE senza iscrizione = nessun errore, count resta 0" do
      sign_in(member)
      delete member_ticket_watch_path(ticket)
      expect(ticket.subscriptions.count).to eq(0)
      expect(response).to redirect_to(member_ticket_path(ticket))
    end
  end
end
