# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets::Votes", type: :request do
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

  describe "PUT update (upvote)" do
    it "non autenticato → redirect login" do
      put member_ticket_vote_path(ticket)
      expect(response).to redirect_to(login_path)
    end

    it "membro assegnato vota → votes_count +1" do
      sign_in(member)
      expect { put member_ticket_vote_path(ticket) }.to change { ticket.reload.votes_count }.by(1)
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "customer assegnato può votare" do
      sign_in(customer)
      expect { put member_ticket_vote_path(ticket) }.to change { ticket.reload.votes_count }.by(1)
    end

    it "voto idempotente: doppio PUT = un solo voto" do
      sign_in(member)
      put member_ticket_vote_path(ticket)
      expect { put member_ticket_vote_path(ticket) }.not_to(change { ticket.reload.votes_count })
      expect(ticket.reload.votes_count).to eq(1)
    end

    it "ticket non visibile (membro org senza accesso al progetto) → 404" do
      sign_in(outsider)
      put member_ticket_vote_path(ticket)
      expect(response).to have_http_status(:not_found)
    end

    it "BOLA: account di un'altra org → 404" do
      sign_in(stranger)
      put member_ticket_vote_path(ticket)
      expect(response).to have_http_status(:not_found)
    end

    it "collisione concorrente (RecordNotUnique) → trattata come successo (idempotente)" do
      sign_in(member)
      allow_any_instance_of(ActiveRecord::Associations::CollectionProxy)
        .to receive(:find_or_create_by!).and_raise(ActiveRecord::RecordNotUnique)

      put member_ticket_vote_path(ticket)

      expect(response).to redirect_to(member_ticket_path(ticket))
    end
  end

  describe "DELETE destroy (rimuovi voto)" do
    it "rimuove il voto → votes_count −1" do
      sign_in(member)
      put member_ticket_vote_path(ticket)
      expect { delete member_ticket_vote_path(ticket) }.to change { ticket.reload.votes_count }.by(-1)
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "rimozione idempotente: DELETE senza voto = nessun errore, count resta 0" do
      sign_in(member)
      delete member_ticket_vote_path(ticket)
      expect(ticket.reload.votes_count).to eq(0)
      expect(response).to redirect_to(member_ticket_path(ticket))
    end
  end

  # CYRA-856 — il pulsante in pagina. Le prove sopra chiamano l'indirizzo del voto direttamente:
  # senza questo, nessuna proverebbe più che il pulsante ci sia dove si vota davvero.
  describe "il pulsante di voto in pagina" do
    it "la scheda del ticket lo mostra col conteggio" do
      sign_in(member)
      get member_ticket_path(ticket)

      expect(response.body).to include('data-test="ticket-vote"')
    end
  end
end
