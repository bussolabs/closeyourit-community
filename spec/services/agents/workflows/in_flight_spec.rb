# frozen_string_literal: true

require "rails_helper"

# CYRA-593 — l'elenco di TUTTE le lavorazioni in volo, comprese quelle che non chiedono niente a
# nessuno. La coda delle approvazioni mostra solo ciò che aspetta una decisione: chi vuole sapere
# chi sta lavorando su cosa, da quanto e dove si è fermato non aveva una pagina che glielo dicesse.
RSpec.describe Agents::Workflows::InFlight do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: organization, key: "ALFA") }
  let(:visible_tickets) { Ticketing::Ticket.where(project_id: organization.projects.select(:id)) }
  let(:visible_projects) { organization.projects }

  before do
    create(:membership, account: account, organization: organization, role: :owner)
    # CYRA-665 — l'elenco è di chi RISPONDE delle lavorazioni: senza essere CTO effettivo di nessun
    # progetto non c'è niente da vedere, ed è un caso a sé (descrive "perimetro di chi risponde").
    organization.update_column(:cto_id, account.id)
  end

  def board(**overrides)
    described_class.call(organization: organization, account: account,
                         visible_tickets: visible_tickets, visible_projects: visible_projects,
                         **overrides)
  end

  def ticket_in(target = project, **attributes)
    create(:ticket, organization: organization, project: target, **attributes)
  end

  # Una lavorazione che l'agente sta ancora facendo: il triage è stato reclamato e nessuno ha
  # chiesto niente a nessuno.
  def running_workflow(target = project, host: nil, **attributes)
    workflow = create(:agent_workflow, ticket: ticket_in(target), triage_requested_at: 2.hours.ago,
                                       triage_started_at: 1.hour.ago, **attributes)
    create(:agent_attempt, workflow: workflow, organization: organization, phase: "triage",
                           status: :running, started_at: 1.hour.ago,
                           **(host ? { host: host } : {}))
    workflow
  end

  # Una lavorazione che aspetta una persona: il piano è pronto e nessuno l'ha ancora approvato.
  def awaiting_workflow(target = project, host: nil)
    create(:agent_workflow, ticket: ticket_in(target), triage_requested_at: 3.hours.ago,
                            triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago,
                            planned_at: 1.hour.ago,
                            **(host ? { planned_by_host: host } : {}))
  end

  # CYRA-630 — le due liste diventano una. Sulla pagina delle decisioni ci sono due numeri: quante
  # cose aspettano te, e quante vanno avanti da sole senza chiederti niente. I due numeri non si
  # sommano mai e non contano mai la stessa riga due volte, e questa è la query del secondo.
  describe "solo ciò che va avanti da solo" do
    it "tiene il lavoro in corso e quello mai avviato, e lascia fuori chi aspetta una persona" do
      in_corso = running_workflow
      mai_avviata = create(:agent_workflow, ticket: ticket_in, triage_requested_at: nil)
      in_attesa = awaiting_workflow

      records = board(autonomous: true).page.records

      expect(records.map(&:workflow)).to contain_exactly(in_corso, mai_avviata)
      expect(records.map(&:workflow)).not_to include(in_attesa)
      expect(records.map(&:state)).to match_array(%w[running idle])
    end

    # Una domanda aperta è una cosa che aspetta una persona, e la coda delle decisioni la conta: se
    # comparisse anche qui, la stessa riga sarebbe contata due volte. La fase non basta a saperlo —
    # una lavorazione con una domanda in sospeso resta in una fase di lavoro — quindi va guardata la
    # domanda, non solo la fase.
    it "una lavorazione con una domanda senza risposta aspetta una persona, e resta fuori" do
      workflow = running_workflow
      attempt = create(:agent_attempt, workflow:, organization: organization)
      create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])

      expect(board(autonomous: true).page.records.map(&:workflow)).not_to include(workflow)
      expect(board.page.records.find { |row| row.workflow == workflow }.state).to eq("waiting")
    end

    # Rispondendo, la lavorazione riparte e torna a essere una che va avanti da sola.
    it "risposta la domanda, torna fra quelle che vanno avanti da sole" do
      workflow = running_workflow
      attempt = create(:agent_attempt, workflow:, organization: organization)
      domanda = create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])
      domanda.update!(answered_at: Time.current)

      expect(board(autonomous: true).page.records.map(&:workflow)).to include(workflow)
    end

    # I due numeri non contano mai la stessa riga due volte: quello che esce di qui è esattamente il
    # complemento di quello che la coda delle decisioni chiama «aspetta te».
    it "il suo totale più quello di chi aspetta una persona fa il totale in volo" do
      running_workflow
      create(:agent_workflow, ticket: ticket_in, triage_requested_at: nil)
      awaiting_workflow

      tutte = board
      autonome = board(autonomous: true)

      expect(tutte.total).to eq(3)
      expect(autonome.total).to eq(2)
      expect(autonome.total + tutte.totals.fetch("waiting", 0)).to eq(tutte.total)
    end

    # Le chip contano solo quello che l'elenco mostra: una chip «aspetta te» su una pagina che non
    # ne mostra nessuna sarebbe un numero su cui non si può cliccare.
    it "i conteggi non nominano più chi aspetta una persona" do
      running_workflow
      awaiting_workflow

      expect(board(autonomous: true).totals.keys).not_to include("waiting")
    end

    # Il filtro di stato resta, ma dentro il perimetro: chiedere «aspetta te» qui non deve aprire una
    # finestra sull'altro elenco.
    it "chiedere lo stato che non c'è non fa uscire niente dall'altro elenco" do
      awaiting_workflow

      expect(board(autonomous: true, state: "waiting").page.records).to be_empty
    end
  end

  describe "perimetro" do
    # Scenario 1 — è il motivo per cui la pagina esiste: in coda non compariva, qui sì.
    it "elenca anche la lavorazione in corso che non chiede nessuna decisione" do
      workflow = running_workflow

      rows = board.page.records

      expect(rows.map(&:workflow)).to eq([ workflow ])
      expect(rows.first.state).to eq("running")
    end

    it "esclude le lavorazioni concluse e quelle annullate" do
      running_workflow
      create(:agent_workflow, ticket: ticket_in, completed_at: Time.current)
      create(:agent_workflow, ticket: ticket_in, cancelled_at: Time.current)

      expect(board.total).to eq(1)
    end

    # Un ticket già chiuso a mano con la lavorazione appesa è lavoro morto: la coda lo esclude
    # (CYRA-316) e questo elenco fa lo stesso, altrimenti i due numeri racconterebbero due storie.
    it "esclude le lavorazioni dei ticket già conclusi" do
      running_workflow
      create(:agent_workflow, ticket: ticket_in(project, status: create(:ticket_status, :done, organization: organization)),
                              triage_requested_at: 1.hour.ago)

      expect(board.total).to eq(1)
    end

    it "esclude le lavorazioni dei ticket che chi guarda non può vedere" do
      running_workflow
      altra = create(:organization)
      create(:agent_workflow, ticket: create(:ticket, organization: altra))

      expect(board.total).to eq(1)
    end
  end

  describe "la riga" do
    # Scenario 2 — è ciò che questa pagina ha in più rispetto a quella del singolo agente.
    it "porta il progetto e l'agente che la sta facendo" do
      host = create(:agent_host, organization: organization, hostname: "mac-uno")
      running_workflow(project, host: host)

      row = board.page.records.first

      expect(row.project).to eq(project)
      expect(row.host).to eq(host)
    end

    it "porta l'ultimo esito, il tempo dell'agente e l'ultima attività" do
      workflow = create(:agent_workflow, ticket: ticket_in, triage_requested_at: 4.hours.ago,
                                         triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago)
      create(:agent_attempt, workflow: workflow, organization: organization, phase: "triage",
                             status: :approved, started_at: 3.hours.ago, finished_at: 3.hours.ago + 60)
      create(:agent_attempt, workflow: workflow, organization: organization, phase: "planner",
                             status: :failed, started_at: 2.hours.ago, finished_at: 2.hours.ago + 30)

      row = board.page.records.first

      expect(row.last_status).to eq("failed")
      expect(row.host_seconds).to eq(90)
      expect(row.last_at).to be_within(1.second).of(2.hours.ago + 30)
    end

    # Il tentativo ancora in volo conta fino ad adesso: una lavorazione partita venti minuti fa non
    # ha lavorato zero secondi, e mostrare un vuoto la farebbe sembrare ferma.
    it "conta anche il tempo del tentativo ancora aperto" do
      workflow = create(:agent_workflow, ticket: ticket_in, triage_requested_at: 2.hours.ago,
                                         triage_started_at: 1.hour.ago)
      create(:agent_attempt, workflow: workflow, organization: organization, phase: "triage",
                             status: :running, started_at: 10.minutes.ago)

      expect(board.page.records.first.host_seconds).to be_within(5).of(600)
    end

    # Una lavorazione appena messa in coda non ha ancora un tentativo: la riga deve esistere lo
    # stesso, dichiarando il vuoto invece di sparire.
    it "esiste anche senza nessun tentativo, e data la riga con l'ultimo movimento" do
      workflow = create(:agent_workflow, ticket: ticket_in, triage_requested_at: 30.minutes.ago)

      row = board.page.records.first

      expect(row.last_status).to be_nil
      expect(row.host_seconds).to be_nil
      expect(row.last_at).to be_within(1.minute).of(workflow.updated_at)
    end

    it "ordina dalla lavorazione toccata per ultima" do
      vecchia = running_workflow
      vecchia.ticket.agent_workflow.attempts.update_all(started_at: 3.days.ago, finished_at: 3.days.ago)
      recente = running_workflow

      expect(board.page.records.map(&:workflow)).to eq([ recente, vecchia ])
    end
  end

  # CYRA-871 — un rilascio che aspetta la produzione dice perché e fino a quando, due righe in blocco
  # per tutta la pagina e mai una per riga.
  describe "il freno prima della produzione" do
    let!(:repository) { create(:github_repository, project:) }

    def in_attesa_della_produzione(verificato_da:)
      ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
      pronta_per!(ticket.agent_workflow, "closer_production")
      ticket.agent_workflow.tap { |workflow| workflow.update!(closer_staging_verified_at: verificato_da) }
    end

    it "durante la prova dello staging porta l'ora da cui può partire" do
      workflow = in_attesa_della_produzione(verificato_da: 30.minutes.ago).reload

      row = board.page.records.find { |record| record.workflow == workflow }

      expect(row.production_hold).to eq(reason: "staging_soak",
                                        until: workflow.closer_staging_verified_at + Agents::Workflows::ProductionHold::WINDOW)
    end

    it "con un errore nuovo in staging lo dice" do
      workflow = in_attesa_della_produzione(verificato_da: 3.hours.ago)
      group = create(:error_group, project:, first_seen_at: 1.hour.ago)
      create(:error_event, group:, environment: "staging", occurred_at: 1.hour.ago)

      row = board.page.records.find { |record| record.workflow == workflow }

      expect(row.production_hold).to eq(reason: "staging_errors")
    end

    it "a freno libero e sulle altre fasi tace" do
      libero = in_attesa_della_produzione(verificato_da: 3.hours.ago)
      altra = running_workflow

      rows = board.page.records.index_by(&:workflow)

      expect(rows.fetch(libero).production_hold).to be_nil
      expect(rows.fetch(altra).production_hold).to be_nil
    end
  end

  describe "stati" do
    # Scenario 4 — la riga che aspetta una persona porta l'azione, quella in corso no.
    it "distingue chi aspetta una persona da chi sta lavorando" do
      awaiting_workflow
      running_workflow

      expect(board.totals).to eq({ "waiting" => 1, "running" => 1 })
      expect(board.total).to eq(2)
    end

    # L'azione porta alla decisione, e decidere sul piano è del solo CTO effettivo: offrire il
    # pulsante a chi riceverebbe un rifiuto sarebbe una promessa che la coda non mantiene.
    it "offre l'azione solo a chi può davvero decidere" do
      project.update!(cto: account)
      awaiting_workflow

      expect(board.page.records.first.decidable).to be(true)
    end

    # Una revisione respinta su una fase che riparte da sé non aspetta nessuno: sta lavorando.
    it "conta come in corso la lavorazione respinta che sta già riprovando" do
      workflow = create(:agent_workflow, ticket: ticket_in, triage_requested_at: 2.days.ago,
                                         triage_started_at: 1.day.ago, triaged_at: 1.day.ago)
      create(:agent_attempt, workflow: workflow, organization: organization, phase: "planner",
                             status: :review_failed, started_at: 1.day.ago, finished_at: 1.day.ago)

      expect(board.totals).to eq({ "running" => 1 })
    end

    it "conta come in attesa la lavorazione respinta rimasta ferma" do
      workflow = create(:agent_workflow, ticket: ticket_in, triage_requested_at: 2.days.ago,
                                         triage_started_at: 1.day.ago)
      create(:agent_attempt, workflow: workflow, organization: organization, phase: "triage",
                             status: :review_failed, started_at: 1.day.ago, finished_at: 1.day.ago)

      expect(board.totals).to eq({ "waiting" => 1 })
    end

    # Una lavorazione creata senza che nessuno abbia chiesto il triage non è né in corso né in
    # attesa: non è mai partita, e dirlo è un'informazione.
    it "tiene a parte la lavorazione mai avviata" do
      create(:agent_workflow, ticket: ticket_in, triage_requested_at: nil)

      expect(board.totals).to eq({ "idle" => 1 })
    end
  end

  # CYRA-665 — l'elenco è di chi RISPONDE di quelle lavorazioni, non di chiunque veda il ticket. Il
  # perimetro è lo stesso della coda delle decisioni: i progetti di cui si è CTO effettivo.
  describe "perimetro di chi risponde" do
    it "non mostra niente a chi non è CTO effettivo di nessun progetto" do
      organization.update_column(:cto_id, create(:account).id)
      running_workflow
      awaiting_workflow

      expect(board).to have_attributes(total: 0, totals: {})
      expect(board.page.records).to be_empty
      expect(described_class.autonomous_count(organization:, account:, visible_tickets:, visible_projects:)).to eq(0)
    end

    it "esclude i progetti affidati a un altro CTO, anche per il CTO dell'organizzazione" do
      altro = create(:project, organization: organization, key: "BETA")
      altro.update_column(:cto_id, create(:account).id)
      running_workflow(altro)
      mia = running_workflow

      expect(board.page.records.map { |row| row.workflow.id }).to eq([ mia.id ])
    end

    it "mostra al CTO di un solo progetto le sole lavorazioni di quel progetto" do
      organization.update_column(:cto_id, nil)
      project.update_column(:cto_id, account.id)
      senza_cto = create(:project, organization: organization, key: "BETA")
      running_workflow(senza_cto)
      mia = running_workflow

      expect(board.page.records.map { |row| row.workflow.id }).to eq([ mia.id ])
    end

    # Il conteggio della home è lo stesso elenco senza le righe: se i due perimetri divergessero, la
    # riga in cima direbbe un numero e l'elenco sotto ne mostrerebbe un altro.
    it "conta solo ciò che va avanti da solo dentro il perimetro" do
      altro = create(:project, organization: organization, key: "BETA")
      altro.update_column(:cto_id, create(:account).id)
      running_workflow(altro)
      running_workflow
      awaiting_workflow

      expect(described_class.autonomous_count(organization:, account:, visible_tickets:, visible_projects:)).to eq(1)
    end
  end

  describe "filtri" do
    let(:altro_progetto) { create(:project, organization: organization, key: "BETA") }

    # Scenario 3 — restano solo le righe che corrispondono, e il conteggio in alto segue il filtro.
    it "restringe a un progetto e fa seguire il conteggio" do
      running_workflow
      running_workflow(altro_progetto)

      filtrato = board(project: "BETA")

      expect(filtrato.page.records.map(&:project)).to eq([ altro_progetto ])
      expect(filtrato.total).to eq(1)
      expect(filtrato.project).to eq("BETA")
    end

    it "restringe a un agente e fa seguire il conteggio" do
      host = create(:agent_host, organization: organization, hostname: "mac-uno")
      running_workflow(project, host: host)
      running_workflow

      filtrato = board(agent: host.id)

      expect(filtrato.page.records.map(&:host)).to eq([ host ])
      expect(filtrato.total).to eq(1)
    end

    it "restringe a uno stato" do
      awaiting_workflow
      running_workflow

      filtrato = board(state: "waiting")

      expect(filtrato.page.records.map(&:state)).to eq([ "waiting" ])
      # I conteggi per stato restano tutti visibili: le chip degli altri devono restare cliccabili.
      expect(filtrato.totals).to eq({ "waiting" => 1, "running" => 1 })
      expect(filtrato.total).to eq(2)
    end

    # Una query string inventata non deve svuotare (né far esplodere) una pagina di sola lettura.
    it "ignora progetto, agente e stato fuori vocabolario" do
      running_workflow

      aperto = board(project: "ZZZZ", agent: SecureRandom.uuid, state: "inventato")

      expect(aperto.total).to eq(1)
      expect(aperto.project).to be_nil
      expect(aperto.agent).to be_nil
      expect(aperto.state).to be_nil
    end

    it "elenca i progetti e gli agenti presenti, per costruire i filtri" do
      primo = create(:agent_host, organization: organization, hostname: "mac-due")
      secondo = create(:agent_host, organization: organization, hostname: "mac-uno")
      running_workflow(project, host: primo)
      running_workflow(altro_progetto, host: secondo)

      aperto = board

      expect(aperto.projects).to contain_exactly(project, altro_progetto)
      # In ordine di nome: i filtri si leggono come un elenco, non come l'ordine in cui è capitato.
      expect(aperto.agents).to eq([ primo, secondo ])
    end
  end

  describe "paginazione" do
    it "taglia la pagina e conta tutto" do
      3.times { running_workflow }

      prima = board(per: 2, page: 1)

      expect(prima.page.records.size).to eq(2)
      expect(prima.page.total).to eq(3)
      expect(prima.page.total_pages).to eq(2)
    end
  end
end
