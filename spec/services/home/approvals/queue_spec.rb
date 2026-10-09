# frozen_string_literal: true

require "rails_helper"

RSpec.describe Home::Approvals::Queue do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :owner) }
  let(:project) { create(:project, organization:) }
  # CTO effettivo via organizzazione: il CTO di progetto va scritto dopo la create (la validazione
  # esige che veda già il progetto), esattamente come fa lo spec della home.
  before { organization.update_column(:cto_id, account.id) }
  let(:visible_projects) { Projects::Project.where(id: project.id) }
  let(:visible_tickets) { Ticketing::Ticket.where(project_id: visible_projects.select(:id)) }
  let(:review_status) { create(:ticket_status, :in_review, organization:) }

  def batch(limit: nil)
    described_class.call(account:, organization:, visible_projects:, visible_tickets:, limit:)
  end

  def build_service
    described_class.new(account:, organization:, visible_projects:, visible_tickets:)
  end

  def create_ticket(**attributes)
    create(:ticket, organization:, project:, **attributes)
  end

  # Ho chiesto precisazioni su questo ticket: commento + evento, nell'ordine che la coda si aspetta.
  def ask_on!(ticket)
    comment = ticket.comments.create!(body: "Serve un chiarimento", author: account)
    Ticketing::Event.create!(organization:, ticket:, actor: account, actor_name: account.name,
                             action: Home::Approvals::Decide::ASK_ACTION, data: { "comment_id" => comment.id })
  end

  describe "coda vuota" do
    it "ritorna zero voci e any? falso" do
      expect(batch).to have_attributes(total: 0, items: [])
      expect(batch.any?).to be(false)
    end
  end

  describe "le quattro sorgenti" do
    it "fonde piani, review, domande e richieste secret, ognuna con la sua chiave" do
      review_ticket = create_ticket(status: review_status, reviewer: account)

      planned = create(:agent_workflow, ticket: create_ticket, planned_at: Time.current)

      asked_ticket = create_ticket(reviewer: account)
      workflow = create(:agent_workflow, ticket: asked_ticket, triage_started_at: Time.current)
      attempt = create(:agent_attempt, workflow:, organization:)
      clarification = create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])

      change_request = create(:secret_change_request, project:, organization:, requested_by: create(:account))

      result = batch

      expect(result.total).to eq(4)
      expect(result.items.map(&:key)).to match_array([
        "review:#{review_ticket.id}", "agent_plan:#{planned.id}",
        "clarification:#{clarification.id}", "secret_change:#{change_request.id}"
      ])
      expect(result.totals).to eq("clarification" => 1, "review" => 1,
                                  "awaiting_approval" => 1, "secret_change" => 1)
      expect(result.items.find { |item| item.kind == :clarification }.subtitle).to eq("Quale ambiente?")
    end

    # CYRA-689 — la coda si fermava a pianificatore/autopilot e diceva «nessuno» dove l'elenco delle
    # lavorazioni in volo, che arriva fino al triage, mostrava il nome della macchina.
    it "attribuisce l'agente con la stessa catena dell'elenco in volo: senza pianificatore registrato vale la macchina del triage" do
      host = create(:agent_host, organization:, hostname: "minion-locale")
      workflow = create(:agent_workflow, ticket: create_ticket, planned_at: Time.current,
                                         triage_by_host_id: host.id)

      item = batch.items.find { |candidate| candidate.key == "agent_plan:#{workflow.id}" }
      expect(item.agent).to have_attributes(id: host.id, name: "minion-locale")
    end

    it "mette in cima le voci ferme da più tempo" do
      recente = create_ticket(status: review_status, reviewer: account, title: "Recente")
      vecchio = create_ticket(status: review_status, reviewer: account, title: "Vecchio")
      vecchio.update_column(:updated_at, 1.year.ago)
      recente.update_column(:updated_at, 1.hour.ago)

      expect(batch.items.map(&:subtitle)).to eq([ "Vecchio", "Recente" ])
    end

    # Il limite taglia le RIGHE caricate, mai i numeri: le chip dei filtri devono dire quante ne
    # aspettano davvero, non quante ne sta mostrando la pila. Vale anche per la card della home, che
    # chiama la coda con `limit: 5` — se i conteggi seguissero il taglio direbbero al massimo cinque.
    it "con limit taglia le voci ma non i conteggi, nemmeno quelli per stato" do
      3.times { create_ticket(status: review_status, reviewer: account) }

      expect(batch(limit: 2).items.size).to eq(2)
      expect(batch(limit: 2).total).to eq(3)
      expect(batch(limit: 2).totals).to eq("review" => 3)
    end

    it "non mostra i piani dei progetti di cui non sono il CTO effettivo" do
      altrui = create(:project, organization:)
      altrui.update_column(:cto_id, create(:account).id)
      ticket = create(:ticket, organization:, project: altrui)
      create(:agent_workflow, ticket:, planned_at: Time.current)

      visible = Projects::Project.where(id: [ project.id, altrui.id ])
      result = described_class.call(account:, organization:, visible_projects: visible,
                                    visible_tickets: Ticketing::Ticket.where(project_id: visible.select(:id)))

      expect(result.total).to eq(0)
    end
  end

  # CYRA-665 — la domanda dell'agente va a chi deve rispondere, non a chiunque veda il progetto.
  describe "a chi va una domanda" do
    def ask_clarification(ticket)
      workflow = create(:agent_workflow, ticket:, triage_started_at: Time.current)
      create(:agent_clarification, workflow:, attempt: create(:agent_attempt, workflow:, organization:),
                                    questions: [ "Quale ambiente?" ])
    end

    it "la propone al revisore del ticket" do
      domanda = ask_clarification(create_ticket(reviewer: account))

      expect(batch.items.map(&:key)).to eq([ "clarification:#{domanda.id}" ])
      expect(batch.totals).to eq("clarification" => 1)
    end

    it "non la propone né la conta a chi vede il ticket senza esserne revisore" do
      altro = create(:account)
      create(:membership, account: altro, organization:, role: :member)
      ask_clarification(create_ticket(reviewer: altro))

      expect(batch.items).to be_empty
      expect(batch).to have_attributes(total: 0, totals: {})
    end

    it "non la propone a nessuno se il ticket non ha un revisore" do
      ask_clarification(create_ticket(reviewer: nil))

      expect(batch.total).to eq(0)
    end

    it "smette di proporla appena qualcuno ha risposto" do
      domanda = ask_clarification(create_ticket(reviewer: account))
      domanda.update!(answered_at: Time.current)

      expect(batch.total).to eq(0)
    end
  end

  describe "in attesa di risposta" do
    let!(:ticket) { create_ticket(status: review_status, reviewer: account) }

    def ask! = ask_on!(ticket)

    it "marca la voce e la manda in fondo alla pila finché nessuno risponde" do
      altro = create_ticket(status: review_status, reviewer: account, title: "Nessuna domanda")
      altro.update_column(:updated_at, 1.hour.ago)
      ticket.update_column(:updated_at, 1.year.ago)
      ask!

      items = batch.items

      expect(items.first.subtitle).to eq("Nessuna domanda")
      expect(items.last.key).to eq("review:#{ticket.id}")
      expect(items.last.waiting_since).to be_present
    end

    it "torna in cima quando arriva una risposta di qualcun altro" do
      collega = create(:account)
      create(:membership, account: collega, organization:, role: :member)
      ask!
      travel_to(1.minute.from_now) { ticket.comments.create!(body: "Ecco la risposta", author: collega) }

      expect(batch.items.first.waiting_since).to be_nil
    end
  end

  # CYRA-290 — lo stato fine è ciò su cui la pagina filtra: se una sorgente smettesse di marcarlo, la sua
  # chip sparirebbe dalla riga dei filtri e quelle righe diventerebbero irraggiungibili se non da "Tutte".
  describe "stato di ogni riga" do
    # Una coda con dentro ogni stato possibile, tranne "waiting" (che è un'annotazione successiva).
    def coda_completa
      {
        "review" => "review:#{create_ticket(status: review_status, reviewer: account).id}",
        "awaiting_approval" => "agent_plan:#{create(:agent_workflow, ticket: create_ticket, planned_at: Time.current).id}",
        "awaiting_autopilot_approval" => "agent_plan:#{consegnato.id}",
        "review_blocked" => "agent_plan:#{fermo.id}",
        "clarification" => "clarification:#{domanda.id}",
        "secret_change" => "secret_change:#{create(:secret_change_request, project:, organization:,
                                                                          requested_by: create(:account)).id}"
      }
    end

    def consegnato
      create(:agent_workflow, ticket: create_ticket, planned_at: 2.minutes.ago,
                              approved_at: 1.minute.ago, autopilot_completed_at: Time.current, candidate_verified_at: Time.current)
    end

    def fermo
      create(:agent_workflow, ticket: create_ticket, triage_started_at: 3.minutes.ago,
                              triaged_at: 2.minutes.ago, planned_at: 1.minute.ago,
                              blocked_at: Time.current, blocked_phase: "triage", blocked_kind: "attempt_limit").tap do |workflow|
        create(:agent_attempt, workflow:, organization:, status: :review_failed, phase: "triage")
      end
    end

    def domanda
      workflow = create(:agent_workflow, ticket: create_ticket(reviewer: account), triage_started_at: Time.current)
      create(:agent_clarification, workflow:, attempt: create(:agent_attempt, workflow:, organization:),
                                    questions: [ "Quale ambiente?" ])
    end

    it "marca ogni sorgente col suo stato, e gli automi con la fase risolta" do
      attesi = coda_completa

      per_chiave = batch.items.to_h { |item| [ item.key, item.state ] }

      expect(per_chiave).to eq(attesi.invert)
      expect(batch.totals).to eq(attesi.keys.index_with { 1 })
    end

    it "chi aspetta una risposta sta solo sotto «in attesa di risposta»" do
      ticket = create_ticket(status: review_status, reviewer: account)
      ask_on!(ticket)

      expect(batch.items.map(&:state)).to eq([ "waiting" ])
      expect(batch.totals).to eq("waiting" => 1)
    end

    # La riclassificazione sposta il conteggio da una parte all'altra: non ne inventa e non ne perde.
    it "spostando una riga in attesa il totale non cambia e la sua famiglia cala di uno" do
      2.times { create_ticket(status: review_status, reviewer: account) }
      ask_on!(create_ticket(status: review_status, reviewer: account))

      expect(batch.totals).to eq("review" => 2, "waiting" => 1)
      expect(batch.total).to eq(3)
    end
  end

  # Il filtro serve a lavorare un gruppo omogeneo dall'inizio alla fine: deve tagliare le righe SENZA
  # toccare i conteggi, o le chip degli altri stati sparirebbero appena ne accendi uno.
  describe "filtro per stato" do
    subject(:filtrata) { filtered("awaiting_approval") }

    let!(:piano) { create(:agent_workflow, ticket: create_ticket, planned_at: Time.current) }
    let!(:in_review) { create_ticket(status: review_status, reviewer: account) }

    def filtered(state)
      described_class.call(account:, organization:, visible_projects:, visible_tickets:, state:)
    end

    it "tiene solo le righe dello stato scelto" do
      expect(filtrata.items.map(&:key)).to eq([ "agent_plan:#{piano.id}" ])
    end

    it "lascia intatti totale e conteggi per stato" do
      expect(filtrata.total).to eq(2)
      expect(filtrata.totals).to eq("awaiting_approval" => 1, "review" => 1)
    end

    it "espone il filtro applicato, così la view sa quale chip accendere" do
      expect(filtrata.filter).to eq("awaiting_approval")
      expect(batch.filter).to be_nil
    end

    it "su uno stato senza righe mostra una pila vuota, non la coda intera" do
      vuoto = filtered("secret_change")

      expect(vuoto.items).to be_empty
      expect(vuoto.totals).not_to have_key("secret_change")
      expect(vuoto.total).to eq(2)
    end

    # Una query string inventata non deve far esplodere una pagina di sola lettura, né mostrare il vuoto:
    # si ignora e si torna alla coda intera.
    it "ignora uno stato che non esiste" do
      inventato = filtered("piano-a-caso")

      expect(inventato.filter).to be_nil
      expect(inventato.items.size).to eq(2)
    end
  end

  # CYRA-790 — il tetto di rendering NON decide quali filtri valgono. Ogni sorgente tagliava a `limit`
  # (i workflow a CANDIDATE_CAP) PRIMA che il filtro entrasse in gioco, e progetto e agente si
  # validavano contro le sole righe caricate: bastava che il primo gruppo occupasse il taglio perché
  # il progetto successivo sparisse dalle scelte e il suo filtro — valido — venisse ignorato in
  # silenzio, riaprendo la coda intera invece di mostrare il lavoro che nascondeva.
  describe "filtro per progetto oltre il taglio" do
    let(:altro) { create(:project, organization:) }
    let(:visible_projects) { Projects::Project.where(id: [ project.id, altro.id ]) }

    def create_altro_ticket(**attributes)
      create(:ticket, organization:, project: altro, **attributes)
    end

    def filtered(key, limit: nil)
      described_class.call(account:, organization:, visible_projects:, visible_tickets:, limit:,
                           project: key)
    end

    # Scenario 1 del ticket: due progetti con decisioni aperte, il primo ne occupa tutto il taglio.
    it "mostra le decisioni del secondo progetto anche quando il primo riempie il taglio" do
      3.times { |i| create_ticket(status: review_status, reviewer: account, title: "Primo #{i}") }
      atteso = create_altro_ticket(status: review_status, reviewer: account, title: "Secondo")

      filtrata = filtered(altro.key, limit: 2)

      expect(filtrata.project).to eq(altro.key)
      expect(filtrata.items.map(&:key)).to eq([ "review:#{atteso.id}" ])
    end

    it "conta le decisioni del filtro, non quelle rimaste nel taglio" do
      3.times { create_ticket(status: review_status, reviewer: account) }
      2.times { create_altro_ticket(status: review_status, reviewer: account) }

      filtrata = filtered(altro.key, limit: 1)

      expect(filtrata.totals).to eq("review" => 2)
      expect(filtrata.total).to eq(2)
    end

    # Le scelte del menu si calcolano sul perimetro pieno: un progetto le cui righe cadono oltre il
    # taglio deve restare raggiungibile, o il suo lavoro non si trova più da nessuna parte.
    it "elenca fra le scelte anche i progetti le cui righe cadono oltre il taglio" do
      3.times { create_ticket(status: review_status, reviewer: account) }
      create_altro_ticket(status: review_status, reviewer: account)

      chiavi = described_class.call(account:, organization:, visible_projects:, visible_tickets:,
                                    limit: 2).projects.map(&:key)

      expect(chiavi).to contain_exactly(project.key, altro.key)
    end

    it "elenca le scelte di tutte le sorgenti, non della sola più affollata" do
      create_ticket(status: review_status, reviewer: account)
      create(:agent_workflow, ticket: create_altro_ticket, planned_at: Time.current)

      expect(batch.projects.map(&:key)).to contain_exactly(project.key, altro.key)
    end

    it "elenca i progetti dei piani agente anche quando le loro righe cadono oltre il taglio" do
      create(:agent_workflow, ticket: create_ticket, planned_at: 2.minutes.ago)
      create(:agent_workflow, ticket: create_altro_ticket, planned_at: Time.current)

      chiavi = described_class.call(account:, organization:, visible_projects:, visible_tickets:,
                                    limit: 1).projects.map(&:key)

      expect(chiavi).to contain_exactly(project.key, altro.key)
    end

    # CYRA-317 — chi riprova da solo esce dalla coda: un progetto che ha soltanto quelle sarebbe una
    # voce di menu che porta a una pila vuota, cioè la stessa promessa mancata da un'altra parte.
    it "non elenca un progetto che ha solo lavorazioni che riprovano da sole" do
      create_ticket(status: review_status, reviewer: account)
      retry_later = create(:agent_workflow, ticket: create_altro_ticket, triage_requested_at: 2.days.ago,
                       triage_started_at: 1.day.ago, triaged_at: 1.day.ago)
      create(:agent_attempt, workflow: retry_later, organization:, status: :review_failed, phase: "planner")

      expect(batch.projects.map(&:key)).to eq([ project.key ])
    end

    # Il cap dei workflow taglia PRIMA della risoluzione della fase: col filtro acceso deve valere
    # sul solo perimetro chiesto, altrimenti i piani vecchi di un progetto nascondono quelli nuovi
    # di un altro.
    it "il tetto dei piani si applica al progetto filtrato, non alla coda intera" do
      stub_const("#{described_class}::CANDIDATE_CAP", 1)
      create(:agent_workflow, ticket: create_ticket, planned_at: 2.minutes.ago)
      atteso = create(:agent_workflow, ticket: create_altro_ticket, planned_at: Time.current)

      filtrata = filtered(altro.key)

      expect(filtrata.items.map(&:key)).to eq([ "agent_plan:#{atteso.id}" ])
      expect(filtrata.totals).to eq("awaiting_approval" => 1)
    end

    it "filtra anche domande e richieste sui segreti, non le sole review" do
      workflow = create(:agent_workflow, ticket: create_altro_ticket(reviewer: account),
                        triage_started_at: Time.current)
      attempt = create(:agent_attempt, workflow:, organization:)
      domanda = create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])
      create(:secret_change_request, project:, organization:, requested_by: create(:account))

      filtrata = filtered(altro.key)

      expect(filtrata.items.map(&:key)).to eq([ "clarification:#{domanda.id}" ])
      expect(filtrata.totals).to eq("clarification" => 1)
    end

    # Un progetto che vedo è un filtro legittimo: se non ha decisioni la risposta è «nessuna», come
    # per uno stato senza righe. Restare filtrati senza poterlo spegnere sarebbe il difetto opposto.
    it "su un progetto visibile senza decisioni mostra la coda vuota e lascia il filtro nel menu" do
      create_ticket(status: review_status, reviewer: account)

      filtrata = filtered(altro.key)

      expect(filtrata.items).to be_empty
      expect(filtrata.project).to eq(altro.key)
      expect(filtrata.projects.map(&:key)).to include(altro.key)
    end

    it "una sigla che non vedo vale come nessun filtro, non come coda vuota" do
      create_ticket(status: review_status, reviewer: account)

      filtrata = filtered("ZZZZ")

      expect(filtrata.project).to be_nil
      expect(filtrata.items.size).to eq(1)
    end
  end

  # CYRA-790 — il confine dichiarato del tetto: sapere se una lavorazione aspetta una persona vuol
  # dire risolverne la fase in Ruby, quindi il menu dei piani si ferma dove si ferma la lettura. È
  # una difesa sul carico, non un giudizio su quali filtri esistano — il filtro del progetto tagliato
  # resta valido e mostra le sue decisioni, che è la promessa del ticket.
  describe "il confine del tetto dei candidati" do
    let(:altro) { create(:project, organization:) }
    let(:visible_projects) { Projects::Project.where(id: [ project.id, altro.id ]) }

    it "oltre il tetto il menu si ferma, ma il filtro di quel progetto resta valido" do
      stub_const("#{described_class}::CANDIDATE_CAP", 1)
      create(:agent_workflow, ticket: create_ticket, planned_at: 2.minutes.ago)
      oltre = create(:agent_workflow,
                     ticket: create(:ticket, organization:, project: altro),
                     planned_at: Time.current)

      expect(batch.projects.map(&:key)).to eq([ project.key ])

      filtrata = described_class.call(account:, organization:, visible_projects:, visible_tickets:,
                                      project: altro.key)
      expect(filtrata.items.map(&:key)).to eq([ "agent_plan:#{oltre.id}" ])
      expect(filtrata.projects.map(&:key)).to include(altro.key)
    end
  end

  # CYRA-790 — la coda e l'elenco delle lavorazioni in volo leggono lo stesso perimetro (anzi, quello
  # di là è più largo): due tetti diversi vorrebbero dire che una lavorazione esiste in una pagina e
  # non nell'altra, ed è il modo in cui il difetto rientrerebbe dalla finestra.
  it "legge fin dove legge l'elenco delle lavorazioni in volo" do
    expect(described_class::CANDIDATE_CAP).to eq(Agents::Workflows::InFlight::CAP)
  end

  # CYRA-448 + CYRA-790 — stessa storia per le macchine: l'agente si validava contro le righe
  # caricate, quindi quello che aveva lasciato in sospeso solo lavoro vecchio spariva dalle scelte.
  describe "filtro per agente oltre il taglio" do
    let(:primo) { create(:agent_host, organization:, hostname: "minion-uno") }
    let(:secondo) { create(:agent_host, organization:, hostname: "minion-due") }

    def filtered(id, limit: nil)
      described_class.call(account:, organization:, visible_projects:, visible_tickets:, limit:,
                           agent: id)
    end

    it "mostra le decisioni della macchina scelta anche quando le altre riempiono il taglio" do
      2.times do
        create(:agent_workflow, ticket: create_ticket, planned_at: 2.minutes.ago, planned_by_host: primo)
      end
      atteso = create(:agent_workflow, ticket: create_ticket, planned_at: Time.current,
                      planned_by_host: secondo)

      filtrata = filtered(secondo.id, limit: 1)

      expect(filtrata.agent).to eq(secondo.id.to_s)
      expect(filtrata.items.map(&:key)).to eq([ "agent_plan:#{atteso.id}" ])
      expect(filtrata.totals).to eq("awaiting_approval" => 1)
    end

    it "il tetto dei piani si applica alla macchina filtrata, non alla coda intera" do
      stub_const("#{described_class}::CANDIDATE_CAP", 1)
      create(:agent_workflow, ticket: create_ticket, planned_at: 2.minutes.ago, planned_by_host: primo)
      atteso = create(:agent_workflow, ticket: create_ticket, planned_at: Time.current,
                      planned_by_host: secondo)

      expect(filtered(secondo.id).items.map(&:key)).to eq([ "agent_plan:#{atteso.id}" ])
    end

    it "elenca fra le scelte anche le macchine le cui righe cadono oltre il taglio" do
      create(:agent_workflow, ticket: create_ticket, planned_at: 2.minutes.ago, planned_by_host: primo)
      create(:agent_workflow, ticket: create_ticket, planned_at: Time.current, planned_by_host: secondo)

      nomi = described_class.call(account:, organization:, visible_projects:, visible_tickets:,
                                  limit: 1).agents.map(&:name)

      expect(nomi).to contain_exactly("minion-uno", "minion-due")
    end

    # Come per i progetti: una macchina che ha soltanto lavorazioni che riprovano da sole non ha
    # lasciato in sospeso nessuna decisione, e nel menu porterebbe a una pila vuota.
    it "non elenca una macchina che ha solo lavorazioni che riprovano da sole" do
      create(:agent_workflow, ticket: create_ticket, planned_at: Time.current, planned_by_host: primo)
      retry_later = create(:agent_workflow, ticket: create_ticket, triage_requested_at: 2.days.ago,
                       triage_started_at: 1.day.ago, triaged_at: 1.day.ago, triage_by_host: secondo)
      create(:agent_attempt, workflow: retry_later, organization:, status: :review_failed, phase: "planner")

      expect(batch.agents.map(&:name)).to eq([ "minion-uno" ])
    end

    # Il pre-filtro SQL restringe alle righe che la macchina si vedrebbe ATTRIBUITE, non a quelle che
    # ha sfiorato: se prendesse anche le seconde, il tetto si riempirebbe di lavorazioni passate ad
    # altri e l'unica davvero sua cadrebbe fuori — il taglio tornerebbe a decidere cosa si vede.
    it "col tetto pieno di lavorazioni sfiorate non perde l'unica attribuita alla macchina" do
      stub_const("#{described_class}::CANDIDATE_CAP", 3)
      3.times do |i|
        create(:agent_workflow, ticket: create_ticket, planned_at: (10 - i).minutes.ago,
               triage_by_host: primo, planned_by_host: secondo)
      end
      atteso = create(:agent_workflow, ticket: create_ticket, planned_at: Time.current,
                      triage_by_host: primo, planned_by_host: primo)

      expect(filtered(primo.id).items.map(&:key)).to eq([ "agent_plan:#{atteso.id}" ])
    end

    # Il pre-filtro resta un sovrainsieme — quale delle tre attribuzioni valga dipende dalla fase,
    # che si risolve in Ruby — quindi il raffinamento sul nome vero della riga deve restare.
    it "non perde la riga attribuita alla macchina dietro quelle che ha solo sfiorato" do
      3.times do |i|
        create(:agent_workflow, ticket: create_ticket, planned_at: (10 - i).minutes.ago,
               triage_by_host: primo, planned_by_host: secondo)
      end
      atteso = create(:agent_workflow, ticket: create_ticket, planned_at: Time.current,
                      triage_by_host: primo, planned_by_host: primo)

      expect(filtered(primo.id).items.map(&:key)).to eq([ "agent_plan:#{atteso.id}" ])
    end

    # Le altre tre famiglie non portano il nome di una macchina: col filtro acceso escono tutte,
    # conteggi compresi — un totale che le contasse racconterebbe una coda che la pila non mostra.
    it "col filtro acceso restano solo le righe che una macchina ce l'hanno" do
      create_ticket(status: review_status, reviewer: account)
      atteso = create(:agent_workflow, ticket: create_ticket, planned_at: Time.current,
                      planned_by_host: primo)

      filtrata = filtered(primo.id)

      expect(filtrata.items.map(&:key)).to eq([ "agent_plan:#{atteso.id}" ])
      expect(filtrata.totals).to eq("awaiting_approval" => 1)
    end

    it "una macchina di un'altra organizzazione vale come nessun filtro" do
      estranea = create(:agent_host, organization: create(:organization))
      create(:agent_workflow, ticket: create_ticket, planned_at: Time.current, planned_by_host: primo)

      filtrata = filtered(estranea.id)

      expect(filtrata.agent).to be_nil
      expect(filtrata.items.size).to eq(1)
    end

    it "un identificativo inventato vale come nessun filtro, non come coda vuota" do
      create(:agent_workflow, ticket: create_ticket, planned_at: Time.current, planned_by_host: primo)

      filtrata = filtered("non-un-identificativo")

      expect(filtrata.agent).to be_nil
      expect(filtrata.items.size).to eq(1)
    end

    # Progetto e macchina si sommano: la coda che resta è l'intersezione, e le scelte dell'uno
    # restano leggibili mentre l'altro è acceso.
    it "progetto e macchina insieme restringono senza spegnere le scelte dell'altro" do
      altro = create(:project, organization:)
      visibili = Projects::Project.where(id: [ project.id, altro.id ])
      atteso = create(:agent_workflow,
                      ticket: create(:ticket, organization:, project: altro),
                      planned_at: Time.current, planned_by_host: secondo)
      create(:agent_workflow, ticket: create_ticket, planned_at: 2.minutes.ago, planned_by_host: primo)

      filtrata = described_class.call(account:, organization:, visible_projects: visibili,
                                      visible_tickets: Ticketing::Ticket.where(project_id: visibili.select(:id)),
                                      project: altro.key, agent: secondo.id)

      expect(filtrata.items.map(&:key)).to eq([ "agent_plan:#{atteso.id}" ])
      expect(filtrata.projects.map(&:key)).to contain_exactly(project.key, altro.key)
      expect(filtrata.agents.map(&:name)).to eq([ "minion-due" ])
    end
  end

  # CYRA-317 — una lavorazione che una revisione ha respinto ma che riparte da sé non aspetta nessuno:
  # stava in una pila intitolata «Da decidere» pur dichiarando, nel suo stesso testo, di non chiedere
  # niente. Ora vive in un elenco separato, fuori dal totale, che si apre solo se lo si vuole guardare.
  describe "ciò che riprova da solo" do
    # Bocciatura sul PLANNER: non ha un avvio dedicato, quindi resta reclamabile e la coda la ripropone
    # da sé. È il caso che l'audit ha trovato in pila a decine.
    def riprova_da_sola
      workflow = create(:agent_workflow, ticket: create_ticket, triage_requested_at: 2.days.ago,
                                         triage_started_at: 1.day.ago, triaged_at: 1.day.ago)
      create(:agent_attempt, workflow:, organization:, status: :review_failed, phase: "planner")
      workflow
    end

    # Bocciatura su una fase CLAIMATA (CYRA-267): lo start resta scritto, la coda non la ripropone più.
    # Ferma davvero: aspetta una persona, e resta in coda.
    def ferma_davvero
      workflow = create(:agent_workflow, ticket: create_ticket, triage_requested_at: 2.days.ago,
                                         triage_started_at: 1.day.ago)
      create(:agent_attempt, workflow:, organization:, status: :review_failed, phase: "triage")
      workflow
    end

    def filtered(state)
      described_class.call(account:, organization:, visible_projects:, visible_tickets:, state:)
    end

    def card_for(key)
      Home::Approvals::Detail.call(account:, organization:, visible_projects:, visible_tickets:, key:)
    end

    # CYRA-630 — dove vanno a finire non è più affare di questa classe: le raccoglie
    # `Agents::Workflows::InFlight`, con un perimetro più largo. Qui resta da provare che ESCANO, e
    # che non si portino dietro né una riga in pila né un numero nel totale.
    it "non la conta nel totale né la mette in pila" do
      riprova_da_sola

      expect(batch.total).to eq(0)
      expect(batch.items).to be_empty
      expect(batch.totals).not_to have_key("review_blocked")
      expect(batch.totals).not_to have_key("retrying")
    end

    it "tiene in coda la lavorazione ferma davvero, che una persona deve sbloccare o chiudere" do
      workflow = ferma_davvero

      expect(batch.items.map(&:key)).to eq([ "agent_plan:#{workflow.id}" ])
      expect(batch.totals).to eq("review_blocked" => 1)
    end

    it "separa le due, senza mescolarne i conteggi" do
      stop = ferma_davvero
      riprova_da_sola

      expect(batch.items.map(&:key)).to eq([ "agent_plan:#{stop.id}" ])
      expect(batch.total).to eq(1)
    end

    # Una domanda su una lavorazione che riprova da sola non la rimette in coda: continuerebbe a
    # contare fra le cose da decidere proprio mentre dichiara di non chiedere niente.
    it "resta fuori dalla coda anche se ho chiesto precisazioni sul suo ticket" do
      workflow = riprova_da_sola
      ask_on!(workflow.ticket)

      expect(batch.total).to eq(0)
      expect(batch.items).to be_empty
      expect(batch.totals).not_to have_key("waiting")
    end

    # È lo stesso discrimine che il pannello usa per offrire (o no) il riaccodo: se divergessero, la
    # coda separerebbe le righe con una regola e la card ne applicherebbe un'altra.
    it "sta nell'elenco separato esattamente quando la card non offre il riaccodo" do
      stop = ferma_davvero
      retry_later = riprova_da_sola

      expect(card_for("agent_plan:#{stop.id}").can?(:approve)).to be(true)
      expect(card_for("agent_plan:#{retry_later.id}").can?(:approve)).to be(false)
    end
  end

  # CYRA-316 — una decisione che aspetta un ticket già concluso (Resolved/Closed = category done) è
  # lavoro morto: fuori dalla pila e fuori dai conteggi, così il numero in testata smette di gonfiarsi
  # di richieste che non servono più. La categoria è fissa (enum), quindi vale per ogni org.
  describe "richieste su ticket in stato finale" do
    let(:done_status) { create(:ticket_status, :done, organization:) }

    it "non propone né conta una domanda il cui ticket è chiuso" do
      chiuso = create_ticket(status: done_status)
      workflow = create(:agent_workflow, ticket: chiuso, triage_started_at: Time.current)
      attempt = create(:agent_attempt, workflow:, organization:)
      create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])

      expect(batch.total).to eq(0)
      expect(batch.items).to be_empty
      expect(batch.totals).not_to have_key("clarification")
    end

    it "non propone né conta un piano il cui ticket è chiuso" do
      create(:agent_workflow, ticket: create_ticket(status: done_status), planned_at: Time.current)

      expect(batch.total).to eq(0)
      expect(batch.totals).not_to have_key("awaiting_approval")
    end

    # CYRA-1066 — the closers own the ticket until production is up: a review row here would offer
    # an Approve that marks it resolved before the release.
    it "leaves out a review whose approved run is still closing" do
      ticket = create_ticket(status: review_status, reviewer: account)
      create(:agent_workflow, :closer_staging_completed, ticket:)

      expect(batch.total).to eq(0)
      expect(batch.totals).not_to have_key("review")
    end

    it "keeps a review whose closing run has completed" do
      ticket = create_ticket(status: review_status, reviewer: account)
      create(:agent_workflow, :closer_staging_completed, ticket:, completed_at: Time.current)

      expect(batch.totals).to eq("review" => 1)
    end

    it "esclude anche una review se il suo status è finale (config non-default)" do
      gate_done = create(:ticket_status, :done, organization:, review_gate: true)
      create_ticket(status: gate_done, reviewer: account)

      expect(batch.total).to eq(0)
    end

    it "tiene in coda le richieste sui ticket ancora aperti" do
      create(:agent_workflow, ticket: create_ticket, planned_at: Time.current)

      expect(batch.total).to eq(1)
    end

    it "non tocca le richieste secret, che non hanno un ticket" do
      create(:secret_change_request, project:, organization:, requested_by: create(:account))

      expect(batch).to have_attributes(total: 1, totals: { "secret_change" => 1 })
    end
  end

  # CYRA-316 — ogni riga porta lo stato del ticket a cui si riferisce (label + colore già pronti per il
  # badge), così si legge a che punto è senza aprire il ticket. Le righe senza ticket (secret) restano nil.
  describe "stato del ticket sulla riga" do
    it "porta label e colore dello status per le righe legate a un ticket" do
      create_ticket(status: create(:ticket_status, :in_review, organization:, color: "violet"), reviewer: account)
      create(:agent_workflow, ticket: create_ticket(status: create(:ticket_status, :in_progress, organization:, color: "indigo")),
                              planned_at: Time.current)

      per_stato = batch.items.to_h { |item| [ item.state, item.ticket_status ] }

      expect(per_stato["review"]).to have_attributes(label: "In Review", color: "violet")
      expect(per_stato["awaiting_approval"]).to have_attributes(label: "In Progress", color: "indigo")
    end

    it "lascia nil lo stato del ticket sulle richieste secret" do
      create(:secret_change_request, project:, organization:, requested_by: create(:account))

      expect(batch.items.first.ticket_status).to be_nil
    end
  end

  # CYRA-504 — lo staging concluso non manda più in produzione da solo: la lavorazione si ferma e
  # chiede il via libera a una persona, che lo dà da qui.
  # ── CYRA-629 ──────────────────────────────────────────────────────────────────────────────────
  #
  # Il terzo permesso non esiste più. Era la terza volta che si chiedeva il via libera sullo stesso
  # lavoro, e non decideva niente di nuovo: fra la seconda approvazione e il sito vero non c'è nessuna
  # scelta da fare, solo fatti da guardare. E aveva una faccia sola — si poteva dire sì, non si poteva
  # dire no: per dire no bisognava NON premere e lasciare la lavorazione ferma, senza che da nessuna
  # parte fosse scritto perché.
  describe "il via libera alla produzione non si chiede più" do
    let!(:workflow) { create(:agent_workflow, :closer_staging_completed, ticket: create_ticket) }

    it "con lo staging concluso non compare nessuna card da autorizzare" do
      expect(batch.items.map(&:key)).not_to include("agent_plan:#{workflow.id}")
      expect(batch.totals).not_to have_key("awaiting_production_approval")
    end

    # E la lavorazione non resta ferma: va in coda per il rilascio da sola.
    it "la lavorazione va in coda per il rilascio, senza aspettare nessuno" do
      expect(workflow.reload.phase).to eq("closer_production_queued")
      expect(Agents::Workflows::PhaseResolver.phase(workflow, Set.new)).to eq("closer_production_queued")
    end

    # Le fermate che aspettano una persona restano due, e sono quelle che decidono qualcosa.
    it "le fasi che aspettano una persona restano due, più il blocco" do
      expect(Agents::Workflows::PhaseResolver::HUMAN_GATED_PHASES)
        .to contain_exactly("awaiting_approval", "awaiting_autopilot_approval", "review_blocked")
    end
  end

  describe "#resolved_phase (parità con Agents::Workflow#phase)" do
    def assert_parity(workflow)
      service = build_service
      failed = service.send(:failed_phases_by_workflow, [ workflow.id ])
      expect(service.send(:resolved_phase, workflow, failed[workflow.id])).to eq(workflow.phase)
    end

    it "coincide a ogni fase del ciclo di vita" do
      workflow = create(:agent_workflow, triage_requested_at: Time.current)
      assert_parity(workflow)

      %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at autopilot_completed_at
         autopilot_approved_at closer_staging_started_at closer_staging_completed_at
         closer_production_approved_at closer_production_started_at completed_at].each do |timestamp|
        workflow.update!(timestamp => Time.current)
        assert_parity(workflow)
      end
    end

    it "coincide su annullamento e review bloccata (per fase attiva e storica)" do
      cancelled = create(:agent_workflow, triage_requested_at: 1.hour.ago, cancelled_at: Time.current)
      assert_parity(cancelled)

      blocked = create(:agent_workflow, triage_started_at: Time.current)
      create(:agent_attempt, workflow: blocked, organization: blocked.ticket.project.organization, status: :review_failed)
      assert_parity(blocked)

      closer = create(:agent_workflow, autopilot_approved_at: 1.minute.ago, closer_staging_started_at: Time.current)
      create(:agent_attempt, workflow: closer, organization: closer.ticket.project.organization,
                             status: :review_failed, phase: "closer_staging")
      assert_parity(closer)
    end

    # CYRA-280 — il filtro "la bocciatura vale solo finché la fase è aperta" vive nel modello e la coda lo
    # riusa: se qui divergessero, la pila delle decisioni continuerebbe a chiamare "ferma per revisione" una
    # lavorazione che la scheda del ticket mostra in attesa di approvazione, con due pulsanti diversi.
    # CYRA-615 — la parità va verificata su TUTTE le fasi che il dominio dichiara, non su quelle che
    # a qualcuno è venuto in mente di elencare: una fase nuova che i due gemelli risolvono in modo
    # diverso passerebbe inosservata proprio qui, dove la parità è il patto.
    it "copre ogni fase dichiarata dal dominio" do
      viste = Set.new
      workflow = create(:agent_workflow, triage_requested_at: Time.current)
      viste << workflow.phase

      %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at autopilot_completed_at
         candidate_verified_at autopilot_approved_at closer_staging_started_at closer_staging_completed_at
         closer_staging_verified_at closer_production_approved_at closer_production_started_at
         closer_production_completed_at completed_at].each do |timestamp|
        workflow.update!(timestamp => Time.current)
        assert_parity(workflow)
        viste << workflow.phase
      end

      fermo = create(:agent_workflow, triage_started_at: Time.current, blocked_at: Time.current,
                                      blocked_phase: "triage", blocked_kind: "attempt_limit")
      assert_parity(fermo)
      viste << fermo.phase
      annullato = create(:agent_workflow, cancelled_at: Time.current)
      assert_parity(annullato)
      viste << annullato.phase
      # `inactive`: nemmeno la valutazione e' stata chiesta. La factory parte gia' con la richiesta,
      # quindi va tolta esplicitamente — ed e' proprio il ramo che nessun'altra prova tocca.
      viste << create(:agent_workflow, triage_requested_at: nil).phase

      expect(viste.to_a.sort).to eq(Agents::Workflows::PhaseResolver::PHASES.sort)
    end

    it "coincide su una bocciatura superata e sul tetto ai tentativi" do
      superata = create(:agent_workflow, triage_started_at: 3.minutes.ago, triaged_at: 2.minutes.ago,
                                         planned_at: 1.minute.ago)
      create(:agent_attempt, workflow: superata, organization: superata.ticket.project.organization,
                             status: :review_failed, phase: "triage")
      assert_parity(superata)
      expect(superata.phase).to eq("awaiting_approval")

      col_tetto = create(:agent_workflow, triage_started_at: 3.minutes.ago, triaged_at: 2.minutes.ago,
                                          planned_at: 1.minute.ago, blocked_at: Time.current,
                                          blocked_phase: "triage", blocked_kind: "attempt_limit")
      create(:agent_attempt, workflow: col_tetto, organization: col_tetto.ticket.project.organization,
                             status: :review_failed, phase: "triage")
      assert_parity(col_tetto)
      expect(col_tetto.phase).to eq("review_blocked")
    end
  end

  # CYRA-284 — la casella di selezione la mostra la coda, ma a decidere davvero è la card. Se qui
  # divergessero, il blocco offrirebbe righe che poi salta in silenzio (o nasconderebbe la casella su
  # righe perfettamente accettabili): la casella diventerebbe una promessa che il server non mantiene.
  describe "#bulk_approvable (parità con Detail::Card#bulk_approvable?)" do
    def assert_bulk_parity(as: account)
      items = described_class.call(account: as, organization:, visible_projects:, visible_tickets:).items
      expect(items).not_to be_empty
      items.each do |item|
        card = Home::Approvals::Detail.call(account: as, organization:, visible_projects:,
                                            visible_tickets:, key: item.key)
        expect(item.bulk_approvable).to eq(card.bulk_approvable?), "divergenza su #{item.key}"
      end
      items.index_by(&:key).transform_values(&:bulk_approvable)
    end

    it "coincide su una coda con tutte le famiglie e tutte le fasi" do
      review_ticket = create_ticket(status: review_status, reviewer: account)
      planned = create(:agent_workflow, ticket: create_ticket, planned_at: Time.current)
      consegnato = create(:agent_workflow, ticket: create_ticket, planned_at: 2.minutes.ago,
                                           approved_at: 1.minute.ago, autopilot_completed_at: Time.current, candidate_verified_at: Time.current)
      fermo = create(:agent_workflow, ticket: create_ticket, triage_started_at: 3.minutes.ago,
                                      triaged_at: 2.minutes.ago, planned_at: 1.minute.ago,
                                      blocked_at: Time.current, blocked_phase: "triage", blocked_kind: "attempt_limit")
      create(:agent_attempt, workflow: fermo, organization:, status: :review_failed, phase: "triage")
      # CYRA-629 — con lo staging concluso la lavorazione non compare più fra le decisioni: il terzo
      # permesso non si chiede, quindi non c'è nessuna card da selezionare.
      in_produzione = create(:agent_workflow, :closer_staging_completed, ticket: create_ticket)
      domanda_workflow = create(:agent_workflow, ticket: create_ticket(reviewer: account), triage_started_at: Time.current)
      attempt = create(:agent_attempt, workflow: domanda_workflow, organization:)
      domanda = create(:agent_clarification, workflow: domanda_workflow, attempt:, questions: [ "Quale ambiente?" ])
      change_request = create(:secret_change_request, project:, organization:, requested_by: create(:account))

      selezionabili = assert_bulk_parity

      expect(selezionabili).not_to have_key("agent_plan:#{in_produzione.id}")
      expect(selezionabili).to eq(
        "review:#{review_ticket.id}" => true,
        "agent_plan:#{planned.id}" => true,
        "agent_plan:#{consegnato.id}" => true,
        "agent_plan:#{fermo.id}" => false,
        "clarification:#{domanda.id}" => false,
        "secret_change:#{change_request.id}" => true
      )
    end

    # Il revisore designato senza tickets.edit vede la riga in pila ma non può decidere: niente casella.
    it "coincide quando il revisore non può gestire il ticket" do
      revisore = create(:account)
      create(:membership, account: revisore, organization:, role: :member)
      create(:project_membership, account: revisore, project:)
      ticket = create_ticket(status: review_status, reviewer: revisore)

      expect(assert_bulk_parity(as: revisore)).to eq("review:#{ticket.id}" => false)
    end
  end
end
