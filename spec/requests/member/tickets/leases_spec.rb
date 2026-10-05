# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets::Leases", type: :request do
  let(:org) { create(:organization) }
  let(:manager) { create(:account) }
  let(:member) { create(:account) }
  let(:stranger) { create(:account) }
  let(:other_org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project:) }
  let(:database_now) { Time.zone.parse("2026-08-06 09:00:00") }

  before do
    create(:membership, account: manager, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: stranger, organization: other_org, role: :member)
    create(:project_membership, account: member, project:)
    allow(Agents::Leases::Clock).to receive(:current).and_return(database_now)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "POST create (prendi in carico)" do
    it "non autenticato → redirect login" do
      post member_ticket_lease_path(ticket)

      expect(response).to redirect_to(login_path)
    end

    it "manager prende il ticket → lease con titolare account e scadenza a 8 ore" do
      sign_in(manager)

      post member_ticket_lease_path(ticket)

      expect(Agents::Lease.where(ticket:).sole).to have_attributes(
        account_id: manager.id, host_id: nil, expires_at: database_now + 8.hours
      )
    end

    # Con un run id stabile per account, il rilascio scriverebbe un tombstone che rende il ticket non
    # più prendibile da quella persona per sempre. Prendere, rilasciare e riprendere è il ciclo normale.
    it "dopo un rilascio la stessa persona può riprendere il ticket" do
      sign_in(manager)
      post member_ticket_lease_path(ticket)
      delete member_ticket_lease_path(ticket)

      post member_ticket_lease_path(ticket)

      expect(flash[:alert]).to be_nil
      expect(Agents::Lease.where(ticket:).sole.account_id).to eq(manager.id)
    end

    it "riprende anche dopo che il proprio lease è scaduto" do
      sign_in(manager)
      post member_ticket_lease_path(ticket)
      Agents::Lease.where(ticket:).update_all(expires_at: database_now - 1.second)

      post member_ticket_lease_path(ticket)

      expect(flash[:alert]).to be_nil
      expect(Agents::Lease.where(ticket:).sole.expires_at).to eq(database_now + 8.hours)
    end

    it "ticket già tenuto da un host → avviso che dice chi lo tiene, senza toccare il lease" do
      host = create(:agent_host, organization: org, hostname: "mac-mini-1")
      lease = create(:agent_lease, organization: org, ticket:, host:, expires_at: database_now + 2.hours)
      sign_in(manager)

      post member_ticket_lease_path(ticket)

      expect(flash[:alert]).to include("mac-mini-1")
      expect(lease.reload.host_id).to eq(host.id)
    end

    # Nel canale member il permesso negato rimanda alla home con un avviso (redirect_to root_path in
    # PermissionGates#require_permission!), non risponde 403 come il canale CLI.
    it "membro senza tickets.assign → rimandato indietro, nessun lease" do
      sign_in(member)

      post member_ticket_lease_path(ticket)

      expect(response).to redirect_to(root_path)
      expect(Agents::Lease.count).to eq(0)
    end

    it "ticket di un'altra organizzazione → 404 (anti-BOLA)" do
      foreign = create(:ticket, organization: other_org, project: create(:project, organization: other_org))
      sign_in(stranger)

      post member_ticket_lease_path(foreign)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy (rilascia)" do
    it "il titolare rilascia → il ticket torna libero" do
      sign_in(manager)
      post member_ticket_lease_path(ticket)

      delete member_ticket_lease_path(ticket)

      expect(Agents::Lease.where(ticket:)).not_to exist
    end

    # Il pulsante compare a chiunque tenga il ticket, anche se l'ha preso dalla riga di comando: il
    # rilascio deve trovare il run di quel lease invece di presumerne uno "web".
    it "rilascia un lease preso dalla riga di comando" do
      create(:agent_lease, organization: org, ticket:, host: nil, agent: nil, account: manager,
                           run_id: "cli:#{SecureRandom.uuid}", expires_at: database_now + 2.hours)
      sign_in(manager)

      delete member_ticket_lease_path(ticket)

      expect(flash[:alert]).to be_nil
      expect(Agents::Lease.where(ticket:)).not_to exist
    end

    it "lease di un altro titolare → avviso, e il lease resta" do
      create(:agent_lease, organization: org, ticket:, host: create(:agent_host, organization: org),
                           expires_at: database_now + 2.hours)
      sign_in(manager)

      delete member_ticket_lease_path(ticket)

      expect(flash[:alert]).to be_present
      expect(Agents::Lease.where(ticket:)).to exist
    end
  end

  describe "resa nella pagina" do
    it "mostra chi sta lavorando il ticket e il pulsante per rilasciarlo al titolare" do
      sign_in(manager)
      post member_ticket_lease_path(ticket)

      get member_ticket_path(ticket)

      expect(response.body).to include("ticket-lease")
      # Il nome si confronta sul testo reso: un apostrofo (Faker ne genera) nel sorgente è `&#39;`.
      expect(Nokogiri::HTML(response.body).text).to include(manager.name)
      expect(response.body).to include("ticket-lease-release")
      expect(response.body).not_to include("ticket-lease-take")
    end

    it "a chi non tiene il ticket non offre nessun pulsante, solo l'avviso" do
      host = create(:agent_host, organization: org, hostname: "mac-mini-1")
      create(:agent_lease, organization: org, ticket:, host:, expires_at: database_now + 2.hours)
      sign_in(manager)

      get member_ticket_path(ticket)

      expect(response.body).to include("mac-mini-1")
      expect(response.body).not_to include("ticket-lease-take")
      expect(response.body).not_to include("ticket-lease-release")
    end

    it "un lease scaduto non viene mostrato e il ticket torna prendibile" do
      create(:agent_lease, organization: org, ticket:, host: create(:agent_host, organization: org),
                           expires_at: database_now - 1.second)
      sign_in(manager)

      get member_ticket_path(ticket)

      expect(response.body).not_to include("ticket-lease-indicator")
      expect(response.body).to include("ticket-lease-take")
    end

    it "l'indicatore compare nella lista dei ticket" do
      create(:agent_lease, organization: org, ticket:, host: create(:agent_host, organization: org),
                           expires_at: 2.hours.from_now)
      sign_in(manager)

      get list_member_tickets_path

      expect(response.body).to include("ticket-lease-indicator-#{ticket.id}")
    end
  end

  # La pagina in italiano è la resa reale per questo utente: il progetto non monta rails-i18n e i
  # formati data/ora di Rails sollevano in `it` se non dichiarati — un badge con l'ora è esattamente
  # il punto dove quel guasto uscirebbe come 500.
  describe "resa in italiano" do
    it "non solleva sui formati data e mostra il badge tradotto" do
      sign_in(manager)
      manager.update!(locale: "it") if manager.respond_to?(:locale)
      post member_ticket_lease_path(ticket)

      get member_ticket_path(ticket), headers: { "Accept-Language" => "it" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ticket-lease")
    end
  end
end
