# frozen_string_literal: true

require "rails_helper"

RSpec.describe Home::Approvals::Detail do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :owner) }
  let(:project) { create(:project, organization:) }
  let(:visible_projects) { Projects::Project.where(id: project.id) }
  let(:visible_tickets) { Ticketing::Ticket.where(project_id: visible_projects.select(:id)) }
  let(:review_status) { create(:ticket_status, :in_review, organization:) }

  before { organization.update_column(:cto_id, account.id) }

  def detail(key)
    described_class.call(account:, organization:, visible_projects:, visible_tickets:, key:)
  end

  def create_ticket(**attributes)
    create(:ticket, organization:, project:, **attributes)
  end

  def open_clarification_on(ticket)
    workflow = ticket.agent_workflow || create(:agent_workflow, ticket:, triage_started_at: 1.hour.ago)
    attempt = create(:agent_attempt, workflow:, organization:)
    create(:agent_clarification, workflow:, attempt:, questions: [ "Quale ambiente?" ])
  end

  describe "chiavi non risolvibili" do
    it "ritorna nil su famiglia sconosciuta o id inesistente" do
      expect(detail("pippo:#{SecureRandom.uuid}")).to be_nil
      expect(detail("review:#{SecureRandom.uuid}")).to be_nil
    end

    it "ritorna nil per un ticket fuori dagli scope visibili" do
      altrove = create(:project, organization: create(:organization))
      ticket = create(:ticket, organization: altrove.organization, project: altrove, with_agent_workflow: true)

      expect(detail("review:#{ticket.id}")).to be_nil
    end
  end

  describe "ticket in review" do
    it "porta le tre decisioni al revisore che può gestire il ticket" do
      ticket = create_ticket(status: review_status, reviewer: account)

      expect(detail("review:#{ticket.id}").decisions).to eq(%i[approve reject ask])
    end

    # Il revisore senza tickets.edit la vede comunque in pila: aprirla deve mostrarle il testo, non
    # un 404. Restano la lettura e la domanda, non la decisione.
    it "al revisore senza tickets.edit resta la sola domanda, e la card si apre lo stesso" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
      ticket = create_ticket(status: review_status, reviewer: member)

      card = described_class.call(account: member, organization:, visible_projects:,
                                  visible_tickets:, key: "review:#{ticket.id}")

      expect(card).to be_present
      expect(card.decisions).to eq(%i[ask])
    end

    it "ritorna nil se il revisore designato è un altro" do
      altro = create(:account)
      create(:membership, account: altro, organization:, role: :member)
      ticket = create_ticket(status: review_status, reviewer: altro)

      expect(detail("review:#{ticket.id}")).to be_nil
    end
  end

  describe "analisi dell'automa" do
    def workflow_in(phase_attributes)
      ticket = create_ticket
      create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago, **phase_attributes)
    end

    it "sul piano pronto offre le tre decisioni, più la rivalutazione" do
      workflow = workflow_in(planned_at: Time.current)

      expect(detail("agent_plan:#{workflow.id}").decisions).to eq(%i[approve reject ask reassess])
    end

    # CYRA-675 — «serve ancora, o è già fatto?» si può chiedere finché il lavoro è dalle parti della
    # pianificazione. Le regole di QUANDO stanno su Agents::Workflow#reassessable? e sono provate lì:
    # qui si verifica solo che la card le offra, e che non le offra dove non valgono.
    describe "la rivalutazione" do
      it "c'è su una lavorazione ferma dalle parti della pianificazione" do
        workflow = create(:agent_workflow, ticket: create_ticket, triage_requested_at: 2.days.ago,
                                           triage_started_at: 1.day.ago)
        create(:agent_attempt, workflow:, organization:, phase: "triage", status: :review_failed)

        card = detail("agent_plan:#{workflow.id}")

        expect(card.phase).to eq("review_blocked")
        expect(card.decisions).to include(:reassess)
      end

      it "non c'è sul lavoro già consegnato dalla macchina" do
        workflow = workflow_in(planned_at: 3.hours.ago, approved_at: 2.5.hours.ago,
                               autopilot_started_at: 2.hours.ago, autopilot_completed_at: 1.hour.ago,
                               candidate_verified_at: 50.minutes.ago)

        card = detail("agent_plan:#{workflow.id}")

        expect(card.phase).to eq("awaiting_autopilot_approval")
        expect(card.decisions).not_to include(:reassess)
      end

      it "non c'è sulla card di una review" do
        ticket = create_ticket(status: review_status, reviewer: account)

        expect(detail("review:#{ticket.id}").decisions).not_to include(:reassess)
      end

      it "non c'è sulla card di una domanda aperta" do
        ticket = create_ticket(status: review_status, reviewer: account)
        clarification = open_clarification_on(ticket)

        expect(detail("clarification:#{clarification.id}").decisions).not_to include(:reassess)
      end
    end

    # CYRA-629 — il via libera alla produzione non si chiede più: con la prova dello staging chiusa
    # la lavorazione va in coda per il rilascio da sola, e nella pila delle decisioni non compare.
    describe "sul via libera alla produzione, che non si chiede più" do
      let(:workflow) { create(:agent_workflow, :closer_staging_completed, ticket: create_ticket) }

      it "non c'è nessuna scheda da decidere" do
        expect(detail("agent_plan:#{workflow.id}")).to be_nil
      end
    end

    # `review_blocked` senza blocked_at = una review fallita, ma la lavorazione riparte da sola:
    # Agents::Workflows::Unblock non farebbe nulla, quindi il pulsante non deve esserci. La bocciatura è del
    # PLANNER — la fase che, non avendo un avvio proprio, resta reclamabile pur risultando bocciata.
    it "su una review fallita che riparte da sola non offre lo sblocco" do
      workflow = workflow_in(triage_started_at: 1.day.ago)
      create(:agent_attempt, workflow:, organization:, status: :review_failed, phase: "planner")

      card = detail("agent_plan:#{workflow.id}")

      expect(card.phase).to eq("review_blocked")
      expect(card.decisions).not_to include(:approve)
    end

    # CYRA-280 — una bocciatura su una fase poi CONCLUSA non è una decisione in sospeso: il triage è stato
    # rifatto e chiuso, tocca al planner. Prima restava in pila per sempre come riga non azionabile, e la
    # stessa maschera nascondeva il piano quando arrivava.
    it "una bocciatura superata non produce nessuna card" do
      workflow = workflow_in({})
      create(:agent_attempt, workflow:, organization:, status: :review_failed, phase: "triage")

      expect(detail("agent_plan:#{workflow.id}")).to be_nil
    end

    # CYRA-267 — il tetto dei tentativi non c'entra: se la fase bocciata era stata claimata, il suo start
    # resta scritto e la coda non la propone più. Ferma è ferma, e il riaccodo deve esserci comunque.
    it "su una fase bocciata che la coda non ripropone offre il riaccodo, anche senza il tetto raggiunto" do
      ticket = create_ticket
      workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago,
                                         triage_started_at: 1.day.ago)
      create(:agent_attempt, workflow:, organization:, phase: "triage", status: :review_failed)

      card = detail("agent_plan:#{workflow.id}")

      expect(card.phase).to eq("review_blocked")
      expect(card.decisions).to include(:approve)
    end

    it "su una lavorazione davvero ferma offre lo sblocco" do
      workflow = workflow_in(triage_started_at: 1.day.ago)
      create(:agent_attempt, workflow:, organization:, status: :review_failed)
      workflow.update!(blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit", blocked_reason: "tetto tentativi")

      expect(detail("agent_plan:#{workflow.id}").decisions).to include(:approve)
    end

    # CYRA-317 — chi apre una lavorazione respinta deve poter decidere se chiuderla, e per farlo deve
    # leggere cosa è stato tentato e cosa ha detto la revisione: senza, si chiude alla cieca.
    describe "il tentativo respinto che spiega il fermo" do
      it "porta l'ultimo tentativo respinto, col verdetto della revisione" do
        # Fase claimata e mai conclusa: ferma davvero, resta in coda (CYRA-267).
        workflow = create(:agent_workflow, ticket: create_ticket, triage_requested_at: 2.days.ago,
                                           triage_started_at: 1.day.ago)
        create(:agent_attempt, workflow:, organization:, phase: "triage", status: :review_failed,
                               started_at: 2.hours.ago, finished_at: 90.minutes.ago,
                               review: { "summary" => "Analisi troppo generica" }, review_status: :changes_requested)
        ultimo = create(:agent_attempt, workflow:, organization:, phase: "triage", status: :review_failed,
                                        started_at: 1.hour.ago, finished_at: 30.minutes.ago,
                                        review: { "summary" => "Manca il caso limite" }, review_status: :changes_requested)

        card = detail("agent_plan:#{workflow.id}")

        expect(card.phase).to eq("review_blocked")
        expect(card.attempt).to eq(ultimo)
        expect(card.attempt.review["summary"]).to eq("Manca il caso limite")
      end

      it "lo porta anche quando la lavorazione sta riprovando da sola" do
        workflow = workflow_in(triage_started_at: 1.day.ago)
        respinto = create(:agent_attempt, workflow:, organization:, status: :review_failed, phase: "planner",
                                          review: { "summary" => "Il piano non copre lo scenario" })

        card = detail("agent_plan:#{workflow.id}")

        expect(card.decisions).not_to include(:approve)
        expect(card.attempt).to eq(respinto)
      end

      it "resta nil sulle fasi che non nascono da una revisione respinta" do
        workflow = workflow_in(planned_at: Time.current)

        expect(detail("agent_plan:#{workflow.id}").attempt).to be_nil
      end
    end
  end

  describe "domanda dell'automa aperta sullo stesso ticket" do
    it "toglie «chiedi precisazioni» dalla card di review" do
      ticket = create_ticket(status: review_status, reviewer: account)
      open_clarification_on(ticket)

      expect(detail("review:#{ticket.id}").decisions).to eq(%i[approve reject])
    end

    it "la card della domanda resta rispondibile" do
      ticket = create_ticket(status: review_status, reviewer: account)
      clarification = open_clarification_on(ticket)

      expect(detail("clarification:#{clarification.id}").decisions).to eq(%i[reply])
    end
  end

  # CYRA-316 — la pila non propone più le richieste su ticket conclusi (category done): il link diretto
  # `?item=` non deve restare una scorciatoia per decidere lavoro morto. Gemello del filtro della coda.
  describe "ticket in stato finale" do
    let(:done_status) { create(:ticket_status, :done, organization:) }

    it "non apre la domanda se il ticket è chiuso" do
      clarification = open_clarification_on(create_ticket(status: done_status))

      expect(detail("clarification:#{clarification.id}")).to be_nil
    end

    it "non apre il piano se il ticket è chiuso" do
      workflow = create(:agent_workflow, ticket: create_ticket(status: done_status), planned_at: Time.current)

      expect(detail("agent_plan:#{workflow.id}")).to be_nil
    end

    it "non apre la review se lo status è finale" do
      gate_done = create(:ticket_status, :done, organization:, review_gate: true)
      ticket = create_ticket(status: gate_done, reviewer: account)

      expect(detail("review:#{ticket.id}")).to be_nil
    end
  end

  # CYRA-557 — la card portava descrizione, analisi tecnica e criteri di accettazione (tutte cose
  # scritte PRIMA che il lavoro cominciasse) e poi offriva Approva/Respingi: cosa fosse stato
  # consegnato non compariva da nessuna parte, e con ottanta decisioni in attesa si approvava sulla
  # fiducia. Il racconto del lavoro è il resoconto del ticket.
  describe "il resoconto del lavoro consegnato" do
    it "la card di revisione porta il resoconto CORRENTE" do
      ticket = create_ticket(status: review_status, reviewer: account)
      create(:ticket_report, ticket:, organization:, body: "Prima stesura")
      corrente = create(:ticket_report, ticket:, organization:, body: "Cosa ho fatto davvero")

      expect(detail("review:#{ticket.id}").report).to eq(corrente)
    end

    it "senza resoconto la card si apre lo stesso, col campo vuoto" do
      ticket = create_ticket(status: review_status, reviewer: account)

      card = detail("review:#{ticket.id}")

      expect(card).to be_present
      expect(card.report).to be_nil
    end

    it "porta il resoconto anche sul lavoro consegnato dall'automa" do
      ticket = create_ticket
      report = create(:ticket_report, ticket:, organization:, body: "Consegnato")
      workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago,
                                         planned_at: 1.day.ago, approved_at: 1.day.ago,
                                         autopilot_started_at: 1.day.ago, autopilot_completed_at: Time.current, candidate_verified_at: Time.current)

      card = detail("agent_plan:#{workflow.id}")

      expect(card.phase).to eq("awaiting_autopilot_approval")
      expect(card.delivered_work?).to be(true)
      expect(card.report).to eq(report)
    end

    # CYRA-389 — la motivazione lunga di un respingimento vive nel resoconto, quindi diventa l'ultima
    # stesura. Come "lavoro consegnato" non vale: chi torna a decidere leggerebbe la propria
    # motivazione di prima al posto del lavoro di adesso.
    it "salta le stesure scritte respingendo il lavoro e mostra quella del lavoro" do
      ticket = create_ticket(status: review_status, reviewer: account)
      lavoro = create(:ticket_report, ticket:, organization:, body: "Cosa ho fatto davvero")
      create(:ticket_report, ticket:, organization:, body: "Manca il caso limite", source: :review_rejection)

      expect(detail("review:#{ticket.id}").report).to eq(lavoro)
    end

    # Su un PIANO il lavoro non è ancora cominciato: un resoconto rimasto da una lavorazione
    # precedente racconterebbe qualcos'altro, e chi decide lo leggerebbe come il lavoro di adesso.
    it "sul piano ancora da approvare non mostra nessun resoconto" do
      ticket = create_ticket
      create(:ticket_report, ticket:, organization:, body: "Di una lavorazione precedente")
      workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago,
                                         planned_at: Time.current)

      card = detail("agent_plan:#{workflow.id}")

      expect(card.delivered_work?).to be(false)
      expect(card.report).to be_nil
    end
  end
end
