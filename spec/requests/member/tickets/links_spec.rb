# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets — collegamenti ticket", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account, name: "Ada Collegamenti") }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }
  let(:related) { create(:ticket, organization: org, project: project) }
  let!(:link) { create(:ticket_link, ticket: ticket, related: related, created_by: owner) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET /member/tickets/:id (sezione collegati)" do
    it "mostra il collegamento su entrambe le show (direzioni opposte)" do
      sign_in(owner)

      get member_ticket_path(ticket)
      expect(response.body).to include("data-test=\"ticket-links\"")
      expect(response.body).to include(related.code)

      get member_ticket_path(related)
      expect(response.body).to include("data-test=\"ticket-links\"")
      expect(response.body).to include(ticket.code)
    end

    it "senza collegamenti la card non compare" do
      link.destroy!
      sign_in(owner)
      get member_ticket_path(ticket)
      expect(response.body).not_to include("data-test=\"ticket-links\"")
    end
  end

  # CYRA-789 — anti-BOLA in lettura: l'altro capo di un collegamento può stare in un progetto che
  # chi guarda non vede (il gate duplicati crea legami CROSS-PROJECT di proposito, via
  # source_ticket_id). Code/title/stato non devono trapelare in nessuna delle due direzioni.
  # `member` è scoped su `project`, quindi un ticket di un altro progetto gli è invisibile.
  describe "GET /member/tickets/:id — capo del collegamento non visibile" do
    let(:hidden_project) { create(:project, organization: org) }
    let(:hidden_ticket) do
      create(:ticket, organization: org, project: hidden_project, title: "Segreto di un altro progetto")
    end

    it "oscura il capo fuori scope: placeholder, niente code/title/link" do
      link.destroy!
      cross = create(:ticket_link, ticket: ticket, related: hidden_ticket, created_by: owner)
      sign_in(member)

      get member_ticket_path(ticket)

      expect(response.body).to include("data-test=\"ticket-links\"")
      expect(response.body).to include("data-test=\"ticket-link-hidden-#{cross.id}\"")
      expect(response.body).not_to include(hidden_ticket.code)
      expect(response.body).not_to include("Segreto di un altro progetto")
      expect(response.body).not_to include("data-test=\"ticket-link-target-#{hidden_ticket.id}\"")
    end

    it "oscura anche nel verso opposto (il ticket nascosto è il capo sorgente)" do
      link.destroy!
      cross = create(:ticket_link, ticket: hidden_ticket, related: ticket, created_by: owner)
      sign_in(member)

      get member_ticket_path(ticket)

      expect(response.body).to include("data-test=\"ticket-link-hidden-#{cross.id}\"")
      expect(response.body).not_to include(hidden_ticket.code)
      expect(response.body).not_to include("Segreto di un altro progetto")
    end

    it "chi vede entrambi i progetti continua a usare il collegamento" do
      link.destroy!
      create(:ticket_link, ticket: ticket, related: hidden_ticket, created_by: owner)
      sign_in(owner)

      get member_ticket_path(ticket)

      expect(response.body).to include("data-test=\"ticket-link-target-#{hidden_ticket.id}\"")
      expect(response.body).to include(hidden_ticket.code)
      expect(response.body).to include("Segreto di un altro progetto")
    end

    it "l'accesso revocato DOPO la creazione oscura il collegamento già scritto" do
      link.destroy!
      access = create(:project_membership, account: member, project: hidden_project)
      cross = create(:ticket_link, ticket: ticket, related: hidden_ticket, created_by: owner)
      sign_in(member)

      get member_ticket_path(ticket)
      expect(response.body).to include(hidden_ticket.code)

      access.destroy!
      get member_ticket_path(ticket)

      expect(response.body).to include("data-test=\"ticket-link-hidden-#{cross.id}\"")
      expect(response.body).not_to include(hidden_ticket.code)
    end

    it "la cronologia non nomina il ticket collegato che il lettore non vede" do
      link.destroy!
      Ticketing::LinkTickets.call(ticket: ticket, targets: [ hidden_ticket ], kind: :related, actor: owner)
      sign_in(member)

      get member_ticket_path(ticket, tab: "discussion")

      expect(response.body).not_to include(hidden_ticket.code)
      expect(response.body).to include("Ada Collegamenti linked another ticket (related)")
    end

    it "la cronologia nomina il ticket collegato a chi lo vede" do
      link.destroy!
      Ticketing::LinkTickets.call(ticket: ticket, targets: [ hidden_ticket ], kind: :related, actor: owner)
      sign_in(owner)

      get member_ticket_path(ticket, tab: "discussion")

      expect(response.body).to include("Ada Collegamenti linked ticket #{hidden_ticket.code} (related)")
    end
  end

  describe "DELETE /member/tickets/:ticket_id/links/:id" do
    it "con permesso tickets.edit rimuove il collegamento" do
      sign_in(owner)
      expect { delete member_ticket_link_path(ticket, link) }
        .to change(Connections::TicketLink, :count).by(-1)
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "senza permesso non rimuove (redirect con alert)" do
      sign_in(member)
      expect { delete member_ticket_link_path(ticket, link) }
        .not_to change(Connections::TicketLink, :count)
      expect(response).to redirect_to(root_path)
    end

    it "link inesistente → alert not_found senza errore" do
      sign_in(owner)
      delete member_ticket_link_path(ticket, SecureRandom.uuid)
      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(flash[:alert]).to eq(I18n.t("member.tickets.links.not_found"))
    end
  end
end
