# frozen_string_literal: true

require "rails_helper"

# CYRA-598 — la macchina dichiara di non poter andare avanti, e il sistema la sente.
#
# Prima: il server accettava la risposta e non faceva niente. Da quel momento la lavorazione restava
# scritta come in corso per sempre — il claim aveva già segnato <fase>_started_at e nessun marcatore
# di conclusione si muoveva — quindi non tornava in coda, non compariva fra quelle che aspettano una
# persona, e la scheda diceva che non serviva niente. L'unica uscita era annullarla.
#
# Qui si prova che ognuno dei cinque punti di consegna ferma la lavorazione, che il blocco porta la
# firma di CHI l'ha scritto, e che «non sono riuscito a guardare» NON è «serve una persona».
RSpec.describe Agents::Attempts::Deliver, "il blocco dichiarato dalla macchina" do
  def scope_per(phase)
    Agents::Lease.where(ticket:).delete_all
    profile = Agents::PhaseProfile.for(phase)
    sa = Accounts::Service::Create.call(organization:, name: "Host SA #{phase}",
                                        project_ids: [ project.id ]).value
    host = create(:agent_host, organization:, service_account: sa, last_heartbeat_at: Time.current,
                               repositories: [ project.key ],
                               runtimes: [ { "name" => profile.runtime, "present" => true } ])
    attempt = create(:agent_attempt, organization:, workflow:, host:, service_account: sa,
                                     skill_key: profile.skill_key, external_run_id: "run-#{phase}",
                                     phase:, runtime: profile.runtime)
    create(:agent_lease, organization:, ticket:, host:, run_id: "run-#{phase}", execution_phase: phase,
                         profile_digest: profile.digest, expires_at: 5.minutes.from_now)
    [ host, attempt, profile.runtime ]
  end

  def consegna(phase, result)
    host, attempt, runtime = scope_per(phase)
    reviewer = runtime == "claude" ? "codex" : "claude"
    described_class.call(
      organization:, host:, attempt:,
      payload: { runtime:, reviewer_runtime: reviewer, result: result.merge(code: ticket.code),
                 review: review_for(phase, summary: "Rapporto onesto e leggibile."),
                 **(Agents::PhaseProfile.for(phase).write_access? ? { observed: observed_head } : {}) }
    )
  end

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :owner) }

  # I campi di classificazione che il contratto del triage esige sempre, qualunque sia lo stato.
  let(:triage_meta) do
    { category: "backend", capabilities: [ "backend" ], risk: "low",
      requires_human_approval: false, reasons: [ "Serve una decisione" ] }
  end

  before do
    workflow.update!(ticket_snapshot_digest: "snapshot")
    organization.update_column(:cto_id, account.id)
  end

  describe "il pianificatore dice «questo non si può fare»" do
    before { workflow.update!(triage_started_at: 2.minutes.ago, triaged_at: 1.minute.ago) }

    # Prima non c'era modo di dirlo: l'agente provava, veniva respinto, riprovava, veniva respinto.
    # Due esecuzioni pagate e buttate, e poi una frase che dava la colpa alla revisione.
    it "viene accettato al PRIMO tentativo, non bocciato" do
      esito = consegna("planner", state: "blocked", reason: "Il ticket è finito nella coda del prodotto sbagliato.")

      expect(esito).to be_ok
      expect(workflow.attempts.where(phase: "planner").sole).to be_status_approved
      expect(workflow.attempts.where(phase: "planner", status: :review_failed).count).to eq(0)
    end

    it "non crea nessun piano e lascia la lavorazione ferma, firmata dalla macchina" do
      consegna("planner", state: "blocked", reason: "Non è pianificabile qui.")

      expect(workflow.reload).to have_attributes(
        planned_at: nil, blocked_phase: "planner", blocked_kind: "agent_blocked"
      )
      expect(workflow.plans).to be_empty
      expect(workflow.blocked_reason).to include("Non è pianificabile qui.")
    end

    it "usa la causa v2 e l'azione umana senza fingere che un retry serva" do
      consegna("planner", contract_version: 2, state: "blocked",
                           failure: { category: "invalid_plan", summary: "Il repository non corrisponde.",
                                      retryable: false, human_action: "Correggere il progetto del ticket." })

      expect(workflow.reload).to have_attributes(blocked_phase: "planner", blocked_kind: "agent_blocked")
      expect(workflow.blocked_reason).to include("Il repository non corrisponde.")
    end

    # La guardia sullo stato non è pulizia: l'effetto del planner fa `fetch` a secco sui quattro campi del
    # piano, che un result bloccato non ha. Senza, la prima consegna bloccata solleva KeyError dentro
    # la transazione — cioè il contratto nuovo romperebbe il server al primo uso.
    it "un piano vero continua a essere creato" do
      consegna("planner", state: "submitted-for-approval", technical_analysis: "Analisi.",
                          scenarios: [ { given: "g", when: "w", then: "t", expected: "e" } ],
                          definition_of_done: [ "fatto" ], notes: [ "nota" ])

      expect(workflow.reload.planned_at).to be_present
      expect(workflow.plans.sole.technical_analysis).to eq("Analisi.")
      expect(workflow.blocked_at).to be_nil
    end
  end

  # CYRA-1062 — the plan the person approved does not fit the code: «Riprova» would rerun the same plan,
  # and an approved plan could not be changed. The work goes back to planning with the reason.
  describe "the machine says the approved plan does not apply" do
    let!(:plan) do
      Agents::Plan.create!(workflow:, attempt: create(:agent_attempt, organization:, workflow:), technical_analysis: "Plan",
                           scenarios: [], definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot",
                           approved_at: 1.hour.ago)
    end

    before do
      workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 3.hours.ago, planned_at: 2.hours.ago,
                       approved_at: 1.hour.ago, autopilot_started_at: 1.minute.ago)
    end

    it "sends the work back to planning with the reason on the plan, without blocking it" do
      result = consegna("autopilot", contract_version: 2, state: "blocked", security_findings: [],
                                     failure: { category: "invalid_plan", summary: "1.1.19 is still vulnerable", retryable: false, human_action: "Replan." })

      expect(result).to be_ok
      expect(workflow.reload).to have_attributes(planned_at: nil, approved_at: nil, blocked_at: nil,
                                                 autopilot_started_at: nil)
      expect(plan.reload.change_request).to eq("1.1.19 is still vulnerable")
      expect(workflow.phase).to eq("planning")
    end

    it "still blocks on any other reason" do
      consegna("autopilot", contract_version: 2, state: "blocked", security_findings: [], failure: { category: "tooling", summary: "pnpm cannot run", retryable: false, human_action: "Fix pnpm." })

      expect(workflow.reload).to have_attributes(blocked_phase: "autopilot", blocked_kind: "agent_blocked")
      expect(plan.reload.change_request).to be_nil
    end
  end

  describe "il triage chiede aiuto" do
    before { workflow.update!(triage_started_at: 1.minute.ago) }

    %w[waiting escalated].each do |stato|
      it "«#{stato}» ferma la lavorazione invece di lasciarla scritta come in corso" do
        consegna("triage", triage_meta.merge(state: stato, reason: "Serve una decisione di prodotto."))

        expect(workflow.reload).to have_attributes(blocked_phase: "triage", blocked_kind: "agent_blocked")
        expect(workflow.blocked_at).to be_present
      end
    end

    # È la misura che conta: prima di questo ticket la lavorazione non compariva affatto nella coda
    # di chi deve decidere, perché il pre-filtro SQL non nominava mai il blocco.
    it "compare fra quelle che aspettano una decisione, e prima non c'era" do
      coda = lambda do
        Home::Approvals::Queue.call(
          account:, organization:,
          visible_projects: Projects::Project.where(id: project.id),
          visible_tickets: Ticketing::Ticket.where(project_id: project.id)
        ).items.map(&:key)
      end

      expect(coda.call).not_to include("agent_plan:#{workflow.id}")
      consegna("triage", triage_meta.merge(state: "escalated", reason: "Serve una decisione di prodotto."))
      expect(coda.call).to include("agent_plan:#{workflow.id}")
    end
  end

  # CYRA-1006 — an escalated triage carries its cause in `reasons`, not `reason`: the stop showed
  # «nessun motivo dichiarato» while the agent had written why it handed the ticket to the team.
  it "writes the last triage reason when an escalated triage has no single reason" do
    workflow.update!(triage_started_at: 1.minute.ago)
    consegna("triage", triage_meta.merge(state: "escalated",
                                         reasons: [ "Area: backend", "Clarification limit reached: escalated to the team" ]))

    expect(workflow.reload.blocked_reason).to eq("Clarification limit reached: escalated to the team")
  end

  # CYRA-1069 — another ticket landed on main first and the approved branch no longer merges: the work
  # goes back to the autopilot, which brings main in, and the new head waits for a person's approval.
  describe "the closer finds the approved branch in conflict with main" do
    before do
      workflow.update!(triage_started_at: 5.minutes.ago, triaged_at: 4.minutes.ago,
                       planned_at: 3.minutes.ago, approved_at: 2.minutes.ago,
                       autopilot_started_at: 1.minute.ago, autopilot_completed_at: 1.minute.ago,
                       autopilot_approved_at: 30.seconds.ago, closer_staging_started_at: 10.seconds.ago)
    end

    let(:conflict) do
      { category: "merge_conflict", summary: "PR #24 conflicts with main.", retryable: false,
        human_action: "Bring main into the ticket branch." }
    end

    it "sends the work back to the autopilot and asks for a new review, without blocking it" do
      result = consegna("closer_staging", state: "blocked", tag: nil, reason: "PR #24 conflicts with main.",
                                          failure: conflict)

      expect(result).to be_ok
      expect(workflow.reload).to have_attributes(blocked_at: nil, autopilot_started_at: nil,
                                                 autopilot_completed_at: nil, autopilot_approved_at: nil,
                                                 closer_staging_started_at: nil, approved_at: be_present)
      expect(workflow.ready_execution_phase).to eq("autopilot")
    end

    it "still blocks on any other reason" do
      consegna("closer_staging", state: "blocked", tag: nil, reason: "The CI is red.",
                                 failure: conflict.merge(category: "quality_gate"))

      expect(workflow.reload).to have_attributes(blocked_phase: "closer_staging", blocked_kind: "agent_blocked")
    end
  end

  describe "«non sono riuscito a guardare» non è «serve una persona»" do
    before do
      workflow.update!(triage_started_at: 5.minutes.ago, triaged_at: 4.minutes.ago,
                       planned_at: 3.minutes.ago, approved_at: 2.minutes.ago,
                       autopilot_started_at: 1.minute.ago, autopilot_completed_at: 1.minute.ago,
                       autopilot_approved_at: 30.seconds.ago, closer_staging_started_at: 10.seconds.ago)
    end

    it "sotto il tetto non blocca, riapre la fase e non chiede niente a nessuno" do
      esito = consegna("closer_staging", state: "blocked", causa: "unreachable", tag: nil,
                                         reason: "Il registro delle immagini non ha risposto.")

      expect(esito).to be_ok
      expect(workflow.reload).to have_attributes(blocked_at: nil, unreachable_count: 1,
                                                 closer_staging_started_at: nil)
      expect(workflow.attempts.where(phase: "closer_staging", status: :review_failed).count).to eq(0)
    end

    it "oltre il tetto ferma la lavorazione, con un motivo che nomina il guasto di lettura" do
      limite = Agents::Constants::PHASE_UNREACHABLE_LIMIT
      limite.times do
        workflow.update!(closer_staging_started_at: 10.seconds.ago)
        consegna("closer_staging", state: "blocked", causa: "unreachable", tag: nil,
                                   reason: "Il registro delle immagini non ha risposto.")
      end

      expect(workflow.reload).to have_attributes(blocked_kind: "agent_blocked", blocked_phase: "closer_staging")
      expect(workflow.blocked_reason).to include("unreachable").and include("non ha risposto")
      expect(workflow.blocked_reason).not_to include("revisione")
    end

    # Il tetto conta i «non riesco a guardare» DI FILA, non quelli di sempre. Senza azzeramento il
    # conteggio è cumulativo per tutta la vita della lavorazione: due letture fallite, una consegna
    # riuscita, e il primo inciampo successivo — che è il primo, non il terzo — farebbe scattare il
    # tetto e chiamerebbe una persona per niente.
    it "una consegna riuscita rompe la serie e riazzera il conteggio" do
      limite = Agents::Constants::PHASE_UNREACHABLE_LIMIT
      (limite - 1).times do
        workflow.update!(closer_staging_started_at: 10.seconds.ago)
        consegna("closer_staging", state: "blocked", causa: "unreachable", tag: nil,
                                   reason: "Il registro non ha risposto.")
      end
      expect(workflow.reload.unreachable_count).to eq(limite - 1)

      workflow.update!(closer_staging_started_at: 10.seconds.ago)
      # CYRA-621 — il numero lo assegna il server prima che la fase parta: senza la riga la consegna
      # è rifiutata, e il conteggio non si azzererebbe per un motivo che non è quello in prova.
      assigned_version(workflow, "closer_staging", version: "v1.2.3-beta.1")
      consegna("closer_staging", state: "staging-released", tag: "v1.2.3-beta.1",
                commit: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29")

      expect(workflow.reload.unreachable_count).to eq(0)
    end

    it "e dopo una consegna riuscita il primo inciampo non blocca" do
      limite = Agents::Constants::PHASE_UNREACHABLE_LIMIT
      (limite - 1).times do
        workflow.update!(closer_staging_started_at: 10.seconds.ago)
        consegna("closer_staging", state: "blocked", causa: "unreachable", tag: nil,
                                   reason: "Il registro non ha risposto.")
      end
      workflow.update!(closer_staging_started_at: 10.seconds.ago)
      # CYRA-621 — il numero lo assegna il server prima che la fase parta: senza la riga la consegna
      # è rifiutata, e il conteggio non si azzererebbe per un motivo che non è quello in prova.
      assigned_version(workflow, "closer_staging", version: "v1.2.3-beta.1")
      consegna("closer_staging", state: "staging-released", tag: "v1.2.3-beta.1",
                commit: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29")

      workflow.update!(closer_staging_started_at: 10.seconds.ago, closer_staging_completed_at: nil)
      consegna("closer_staging", state: "blocked", causa: "unreachable", tag: nil,
                                 reason: "Il registro non ha risposto di nuovo.")

      expect(workflow.reload).to have_attributes(blocked_at: nil, unreachable_count: 1)
    end

    # `causa` assente vale needs_decision: è il default sicuro. Chiamare una persona che non serviva
    # costa un'occhiata; non chiamarla quando serviva ferma la lavorazione per sempre.
    it "senza `causa` si comporta come «serve una persona»" do
      consegna("closer_staging", state: "blocked", tag: nil, reason: "Il repository non ha un canale di prova.")

      expect(workflow.reload.blocked_at).to be_present
      expect(workflow.unreachable_count).to eq(0)
    end
  end

  describe "la lettura della fase" do
    before do
      workflow.update!(triage_started_at: 5.minutes.ago, triaged_at: 4.minutes.ago,
                       planned_at: 3.minutes.ago, approved_at: 2.minutes.ago,
                       autopilot_started_at: 90.seconds.ago, autopilot_completed_at: 80.seconds.ago,
                       autopilot_approved_at: 70.seconds.ago, closer_staging_started_at: 60.seconds.ago)
    end

    # Le due letture sono copie l'una dell'altra e finora nessuno provava che dicessero la stessa
    # cosa su una lavorazione bloccata: lo spec di parità confronta le stringhe del sorgente, non il
    # comportamento. Un blocco su un closer restava «in corso» in tutte e due.
    it "dice «ferma» in tutte e due le letture, non «in corso»" do
      consegna("closer_staging", state: "blocked", tag: nil, reason: "Manca il canale di prova.")

      workflow.reload
      failed = Agents::Workflows::PhaseResolver.failed_phases_by_workflow([ workflow.id ])[workflow.id]
      expect(workflow.phase).to eq("review_blocked")
      expect(Agents::Workflows::PhaseResolver.phase(workflow, failed)).to eq("review_blocked")
    end

    # La condizione nomina staging E produzione: sono due rami diversi della catena, e quello della
    # produzione ha un effetto in più — trattiene la fila dei rilasci di tutto il repository finché
    # qualcuno non sblocca (ProductionLock guarda blocked_phase, non solo i rilasci avviati).
    it "vale anche per un rilascio di produzione, e quello trattiene la fila" do
      workflow.update!(closer_staging_completed_at: 50.seconds.ago,
                       closer_production_approved_at: 40.seconds.ago,
                       closer_production_started_at: 30.seconds.ago)

      consegna("closer_production", state: "blocked", tag: nil, reason: "Il rilascio non è ripartito.")

      workflow.reload
      failed = Agents::Workflows::PhaseResolver.failed_phases_by_workflow([ workflow.id ])[workflow.id]
      expect(workflow.phase).to eq("review_blocked")
      expect(Agents::Workflows::PhaseResolver.phase(workflow, failed)).to eq("review_blocked")
      expect(workflow.blocked_phase).to eq("closer_production")
      expect(Agents::Workflows::ProductionLock.holder(project:)).to be_present
    end

    it "e la coda non ripropone più quella lavorazione" do
      consegna("closer_staging", state: "blocked", tag: nil, reason: "Manca il canale di prova.")

      expect(workflow.reload.ready_execution_phase).to be_nil
    end
  end

  describe "il pulsante che la rimette in moto" do
    before { workflow.update!(triage_started_at: 1.minute.ago) }

    # Le due misure insieme sono la prova che il pulsante ha un effetto: prima dello sblocco la coda
    # non la restituisce mai, subito dopo la restituisce per la fase del blocco. Prima di CYRA-598
    # lo sblocco non riapriva niente su un blocco d'agente, perché cercava la fase fra gli attempt
    # bocciati e un blocco d'agente non ne produce nessuno.
    it "riapre la fase scritta nel blocco" do
      consegna("triage", triage_meta.merge(state: "escalated", reason: "Serve una decisione di prodotto."))
      expect(workflow.reload.ready_execution_phase).to be_nil

      Agents::Workflows::Unblock.call(workflow: workflow.reload, actor: account)

      expect(workflow.reload.ready_execution_phase).to eq("triage")
      expect(workflow.blocked_at).to be_nil
      expect(workflow.blocked_kind).to be_nil
      expect(workflow.unreachable_count).to eq(0)
    end
  end
end
