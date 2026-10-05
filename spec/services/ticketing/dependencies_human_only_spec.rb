# frozen_string_literal: true

require "rails_helper"

# CYRA-596 — i prerequisiti li decide una persona.
#
# Le macchine entrano nel sistema con un'utenza di servizio che ha `tickets.edit` sul progetto: le
# serve per spostare lo stato del ticket a fine lavoro. Con lo stesso permesso poteva aggiungere un
# prerequisito che nessuno aveva voluto, o togliere quello deciso da una persona — e non se ne
# accorgeva nessuno: spariva una riga da un elenco, il ticket bloccato ripartiva da solo, e in
# cronologia restava il nome di un programma accanto a una decisione che era di qualcun altro.
#
# Nel disegno nuovo quei legami sono l'unica cosa che tiene in piedi l'ordine deciso da chi approva
# il piano. Se li può riscrivere la macchina che deve obbedirgli, quell'ordine non è una decisione:
# è un suggerimento.
RSpec.describe "i prerequisiti li decide una persona" do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open") }
  let(:ticket) { create(:ticket, organization: org, project: project, status: open_status) }
  let(:blocker) { create(:ticket, organization: org, project: project, status: open_status) }
  let(:visible) { Ticketing::Ticket.where(project_id: org.projects.select(:id)) }

  # L'utenza con cui entrano le macchine: ha davvero il permesso di modifica sui ticket, e questo è
  # il punto — il rifiuto non deve dipendere dai permessi, ma da CHI sta chiedendo.
  let(:programma) do
    Accounts::Service::Create.call(organization: org, name: "Host", project_ids: [ project.id ]).value
  end
  # Una persona qualunque, NON owner e non amministratore assoluto: se il rifiuto passasse solo agli
  # owner starebbe guardando il privilegio invece di chi sta chiedendo, ed è la distinzione che
  # questo lavoro esiste per fare. Il permesso di modifica lo verifica il controller, non questi
  # servizi: qui conta solo che a passare sia una persona.
  let(:persona) do
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
  end

  describe "aggiungere" do
    it "un programma viene respinto, e sul ticket non cambia niente" do
      esito = nil
      expect do
        esito = Ticketing::AddDependency.call(ticket:, blocker_id: blocker.id,
                                              visible_tickets: visible, actor: programma)
      end.not_to change(Connections::TicketDependency, :count)

      expect(esito).to be_err
      expect(esito.error.code).to eq("R403-TICKET-001")
      expect(ticket.reload.blockers).to be_empty
      expect(ticket.events.where(action: "dependency_added")).to be_empty
    end

    # Lo STESSO prerequisito, subito dopo: prova che a essere rifiutata era l'utenza, non la richiesta.
    it "e subito dopo la stessa persona lo aggiunge, col suo nome" do
      Ticketing::AddDependency.call(ticket:, blocker_id: blocker.id, visible_tickets: visible, actor: programma)

      esito = Ticketing::AddDependency.call(ticket:, blocker_id: blocker.id,
                                            visible_tickets: visible, actor: persona)

      expect(esito).to be_ok
      expect(ticket.reload.blockers).to include(blocker)
      expect(ticket.events.find_by(action: "dependency_added").actor).to eq(persona)
    end

    # Un servizio invocato senza attore — uno script, un lavoro interno — non deve poter scrivere un
    # legame senza nome: sarebbe una decisione che non appartiene a nessuno.
    it "senza nessun attore viene respinto prima di scrivere" do
      expect do
        esito = Ticketing::AddDependency.call(ticket:, blocker_id: blocker.id, visible_tickets: visible)
        expect(esito.error.code).to eq("R403-TICKET-001")
      end.not_to change(Connections::TicketDependency, :count)
    end

    # Il codice deve essere il suo: «permesso negato» generico o «ticket non trovato» direbbero che
    # il problema è altrove, e la seconda cambierebbe risposta a seconda di cosa esiste.
    it "col codice suo, non il blocker non trovato" do
      esito = Ticketing::AddDependency.call(ticket:, blocker_id: SecureRandom.uuid,
                                            visible_tickets: visible, actor: programma)

      expect(esito.error.code).to eq("R403-TICKET-001")
    end
  end

  describe "togliere" do
    let!(:dipendenza) do
      Ticketing::AddDependency.call(ticket:, blocker_id: blocker.id,
                                    visible_tickets: visible, actor: persona).value
    end

    it "un programma viene respinto e il prerequisito resta al suo posto" do
      esito = nil
      expect do
        esito = Ticketing::RemoveDependency.call(ticket:, dependency_id: dipendenza.id, actor: programma)
      end.not_to change(Connections::TicketDependency, :count)

      expect(esito).to be_err
      expect(esito.error.code).to eq("R403-TICKET-001")
      expect(ticket.reload.blockers).to include(blocker)
      expect(ticket.events.where(action: "dependency_removed")).to be_empty
    end

    it "e subito dopo la stessa persona lo toglie davvero" do
      Ticketing::RemoveDependency.call(ticket:, dependency_id: dipendenza.id, actor: programma)

      expect do
        Ticketing::RemoveDependency.call(ticket:, dependency_id: dipendenza.id, actor: persona)
      end.to change(Connections::TicketDependency, :count).by(-1)
      expect(ticket.reload.blockers).to be_empty
    end

    # Il controllo sta PRIMA della ricerca: rispondere «non trovato» a chi non aveva comunque il
    # diritto di chiedere racconterebbe a una macchina quali prerequisiti ci sono sul ticket.
    it "col codice suo anche su un prerequisito che non esiste" do
      esito = Ticketing::RemoveDependency.call(ticket:, dependency_id: SecureRandom.uuid, actor: programma)

      expect(esito.error.code).to eq("R403-TICKET-001")
    end
  end

  # Il messaggio deve dire dove si decidono i prerequisiti: un rifiuto che non dice cosa fare
  # lascia chi legge esattamente dov'era.
  it "il messaggio dice dove si decidono i prerequisiti" do
    esito = Ticketing::AddDependency.call(ticket:, blocker_id: blocker.id,
                                          visible_tickets: visible, actor: programma)

    # Confronto con la chiave, non col testo: la suite gira in inglese e la scheda si legge in
    # italiano — asserire le parole italiane proverebbe solo in che lingua gira la prova.
    expect(esito.error.message).to eq(I18n.t("member.tickets.dependencies.errors.human_only"))
    expect(esito.error.message).not_to eq(I18n.t("member.tickets.dependencies.errors.invalid"))
    expect(esito.error.message).not_to eq(I18n.t("member.tickets.dependencies.errors.not_found"))
  end
end
