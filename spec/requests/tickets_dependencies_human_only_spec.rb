# frozen_string_literal: true

require "rails_helper"

# CYRA-596 — il rifiuto arriva uguale su tutti e due i canali.
#
# Il canale a token è quello che usano le macchine, ed è già aperto oggi: accetta «aggiungi un
# prerequisito» e «togli un prerequisito» con la stessa chiave che l'agente ha in tasca per il resto
# del suo lavoro. La pagina è l'altro, e ci si arriva solo facendo agire un amministratore assoluto
# «come» quell'utenza di servizio — un'utenza di servizio da sola non fa login web.
#
# Quattro casi, non due: aggiunta e rimozione per ciascun canale. Il codice deve essere sempre il
# suo, mai il generico permesso negato e mai «prerequisito non trovato», che direbbe che il problema
# è il dato e cambierebbe risposta a seconda di cosa esiste sul ticket.
RSpec.describe "prerequisiti: solo una persona, su tutti i canali", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open") }
  let(:ticket) { create(:ticket, organization: org, project: project, status: open_status) }
  let(:blocker) { create(:ticket, organization: org, project: project, status: open_status) }

  let(:persona) { create(:account) }
  let!(:membership) { create(:membership, account: persona, organization: org, role: :owner) }
  # L'utenza con cui entrano le macchine. Ha `tickets.edit` sul progetto: le serve per spostare lo
  # stato del ticket a fine lavoro, ed è esattamente il permesso con cui potrebbe toccare i
  # prerequisiti. Il rifiuto non deve dipendere dai permessi, ma da chi sta chiedendo.
  let(:programma) do
    Accounts::Service::Create.call(organization: org, name: "Host", project_ids: [ project.id ]).value
      .tap do |conto|
        # Il permesso è VERO, ed è il punto di tutta la prova: se il rifiuto arrivasse dal gate dei
        # permessi non avremmo dimostrato niente — l'host quel permesso ce l'ha davvero, gli serve
        # per spostare lo stato del ticket a fine lavoro, ed è con quello che potrebbe toccare i
        # prerequisiti.
        Authorization::SetAccountPermissions.call(
          organization: org, account: conto, allow_keys: [ "tickets.edit" ], actor: persona
        )
      end
  end
  let!(:prerequisito) do
    Ticketing::AddDependency.call(
      ticket:, blocker_id: blocker.id, actor: persona,
      visible_tickets: Ticketing::Ticket.where(project_id: org.projects.select(:id))
    ).value
  end

  describe "il canale a token" do
    def intestazione(account)
      segreto = Accounts::ApiTokens::Issue.call(account:, organization: org, name: "CLI").value[:secret]
      { "Authorization" => "Bearer #{segreto}" }
    end

    def percorso
      "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/dependencies"
    end

    it "rifiuta l'aggiunta chiesta da un programma, col codice suo" do
      expect do
        post percorso, params: { blocker: blocker.id }, headers: intestazione(programma)
      end.not_to change(Connections::TicketDependency, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-TICKET-001")
    end

    it "rifiuta la rimozione chiesta da un programma, e il prerequisito resta" do
      expect do
        delete "#{percorso}/#{prerequisito.id}", headers: intestazione(programma)
      end.not_to change(Connections::TicketDependency, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-TICKET-001")
      expect(ticket.reload.blockers).to include(blocker)
    end
  end

  describe "la pagina del ticket" do
    let(:god) { create(:account, god: true) }

    def entra_come(account)
      enable_two_factor!(account) if account.god? && !account.otp_enabled?
      post login_path, params: { email: account.email, password: "Secret123!" }
      complete_two_factor(account) if account.otp_enabled?
    end

    # Un'utenza di servizio non fa login web: l'unico modo per farla agire sulla pagina è che un
    # amministratore assoluto agisca «come» lei. È anche l'unico modo in cui potrebbe succedere
    # davvero.
    before do
      create(:membership, account: god, organization: org, role: :admin)
      entra_come(god)
      start_impersonation_as(god, account_id: programma.id) # CYRA-719: l'avvio passa dal secondo fattore
    end

    it "l'aggiunta mostra il messaggio che dice dove si decidono i prerequisiti" do
      expect do
        post member_ticket_dependencies_path(ticket), params: { blocker_id: blocker.id }
      end.not_to change(Connections::TicketDependency, :count)

      expect(flash[:alert]).to eq(I18n.t("member.tickets.dependencies.errors.human_only"))
    end

    # È il caso che oggi mostra il generico «prerequisito non trovato»: il controller scartava il
    # messaggio del servizio e ne stampava uno fisso, quindi l'unico rifiuto che dice cosa fare
    # arrivava travestito da dato mancante.
    it "anche la rimozione mostra quel messaggio, non «prerequisito non trovato»" do
      expect do
        delete member_ticket_dependency_path(ticket, prerequisito)
      end.not_to change(Connections::TicketDependency, :count)

      expect(flash[:alert]).to eq(I18n.t("member.tickets.dependencies.errors.human_only"))
      expect(flash[:alert]).not_to eq(I18n.t("member.tickets.dependencies.errors.not_found"))
      expect(ticket.reload.blockers).to include(blocker)
    end
  end
end
