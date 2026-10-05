# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Workflow, type: :model do
  it "è uno a uno col ticket" do
    workflow = create(:agent_workflow)

    expect(build(:agent_workflow, ticket: workflow.ticket)).not_to be_valid
  end

  describe "#phase" do
    it "deriva le fasi senza cambiare lo status editoriale del ticket" do
      workflow = create(:agent_workflow, triage_requested_at: Time.current)
      original_status = workflow.ticket.status

      expect(workflow.phase).to eq("triage_queued")
      workflow.update!(triage_started_at: Time.current)
      expect(workflow.phase).to eq("triaging")
      workflow.update!(triaged_at: Time.current)
      expect(workflow.phase).to eq("planning")
      workflow.update!(planned_at: Time.current)
      expect(workflow.phase).to eq("awaiting_approval")
      workflow.update!(approved_at: Time.current)
      expect(workflow.phase).to eq("autopilot_queued")
      workflow.update!(autopilot_started_at: Time.current)
      expect(workflow.phase).to eq("autopilot")
      # CYRA-612/615 — consegnare non basta più: la fase «aspetta la tua approvazione» esiste solo dopo
      # che il sistema ha aperto la proposta e letto i controlli su quel codice. In mezzo la
      # lavorazione ha un nome suo, e non si racconta come lavoro che l'agente sta ancora scrivendo.
      workflow.update!(autopilot_completed_at: Time.current)
      expect(workflow.phase).to eq("verifying_candidate")
      workflow.update!(candidate_verified_at: Time.current)
      expect(workflow.phase).to eq("awaiting_autopilot_approval")
      workflow.update!(autopilot_approved_at: Time.current)
      expect(workflow.phase).to eq("closer_staging_queued")
      workflow.update!(closer_staging_started_at: Time.current)
      expect(workflow.phase).to eq("closer_staging")
      workflow.update!(closer_staging_completed_at: Time.current, closer_staging_verified_at: Time.current)
      # CYRA-629 — dalla prova dello staging alla coda del rilascio non c'è più nessuna fermata.
      expect(workflow.phase).to eq("closer_production_queued")
      workflow.update!(closer_production_started_at: Time.current)
      expect(workflow.phase).to eq("closer_production")
      workflow.update!(completed_at: Time.current)
      expect(workflow.phase).to eq("completed")
      expect(workflow.ticket.reload.status).to eq(original_status)
    end

    it "dà precedenza all'annullamento" do
      workflow = create(:agent_workflow, triage_requested_at: 1.hour.ago, cancelled_at: Time.current)

      expect(workflow.phase).to eq("cancelled")
    end

    it "deriva il blocco di review dai tentativi falliti chiusi" do
      workflow = create(:agent_workflow, triage_started_at: Time.current)
      create(:agent_attempt, workflow:, status: :review_failed)

      expect(workflow.phase).to eq("review_blocked")
    end

    it "le fasi post-autopilot hanno precedenza su un tentativo fallito storico" do
      workflow = create(:agent_workflow, autopilot_started_at: Time.current, autopilot_completed_at: Time.current,
                                         candidate_verified_at: Time.current)
      create(:agent_attempt, workflow:, status: :review_failed)

      expect(workflow.phase).to eq("awaiting_autopilot_approval")
    end

    it "un closer_staging attivo con attempt fallito DI STAGING è review_blocked, con precedenza sulla fase attiva" do
      workflow = create(:agent_workflow, autopilot_approved_at: 1.minute.ago, closer_staging_started_at: Time.current)
      create(:agent_attempt, workflow:, status: :review_failed, phase: "closer_staging")

      expect(workflow.phase).to eq("review_blocked")
    end

    it "un closer_production attivo con attempt fallito DI PRODUCTION è review_blocked" do
      workflow = create(:agent_workflow, closer_staging_completed_at: 1.minute.ago, closer_staging_verified_at: 1.minute.ago,
                                         closer_production_started_at: Time.current)
      create(:agent_attempt, workflow:, status: :review_failed, phase: "closer_production")

      expect(workflow.phase).to eq("review_blocked")
    end

    it "un closer_staging fallito e SUPERATO non blocca closer_production (fallimento filtrato per phase)" do
      workflow = create(:agent_workflow, closer_staging_started_at: 3.minutes.ago,
                                         closer_staging_completed_at: 2.minutes.ago, closer_staging_verified_at: 2.minutes.ago,
                                         closer_production_started_at: Time.current)
      create(:agent_attempt, workflow:, status: :review_failed, phase: "closer_staging")

      expect(workflow.phase).to eq("closer_production")
    end

    it "un fallito storico NON blocca una fase closer già completata (va in coda per il rilascio)" do
      workflow = create(:agent_workflow, closer_staging_started_at: 2.minutes.ago,
                                         closer_staging_completed_at: 1.minute.ago, closer_staging_verified_at: 1.minute.ago)
      create(:agent_attempt, workflow:, status: :review_failed)

      expect(workflow.phase).to eq("closer_production_queued")
    end

    # CYRA-629 — il terzo permesso non si chiede più. Fra la seconda approvazione e il sito vero non
    # c'è nessuna scelta da fare, solo fatti da guardare: appena la PROVA dello staging è chiusa
    # (osservata dal sistema, non dichiarata da una macchina) la lavorazione va in coda da sola.
    it "con la prova dello staging chiusa va in coda per il rilascio, senza aspettare nessuno" do
      workflow = create(:agent_workflow, :closer_staging_completed)

      expect(workflow.phase).to eq("closer_production_queued")

      workflow.update!(closer_production_approved_at: Time.current)

      expect(workflow.phase).to eq("closer_production_queued")
    end

    # CYRA-280 — gli attempt sono audit immutabile: una bocciatura resta in archivio anche quando la fase è
    # stata rifatta e conclusa. Finché contava per sempre, un triage bocciato una volta mascherava OGNI fase
    # successiva: il piano arrivava, la scheda diceva "ferma per revisione" e nessun canale offriva
    # l'approvazione (i pulsanti guardano awaiting_approval, la coda decisioni chiede blocked_at o una fase
    # ferma). La lavorazione moriva col piano pronto in mano.
    it "una bocciatura su una fase GIÀ CONCLUSA non maschera la fase corrente" do
      workflow = create(:agent_workflow, triage_started_at: 3.minutes.ago, triaged_at: 2.minutes.ago,
                                         planned_at: 1.minute.ago)
      create(:agent_attempt, workflow:, status: :review_failed, phase: "triage")

      expect(workflow.phase).to eq("awaiting_approval")
    end

    # Il planner non ha un avvio dedicato (non compare in PHASE_START_COLUMNS), ma si conclude eccome: il
    # piano prodotto è planned_at. Senza questo, la sua bocciatura sarebbe l'unica a restare eterna.
    it "una bocciatura del planner non maschera il piano che è poi arrivato" do
      workflow = create(:agent_workflow, triage_started_at: 3.minutes.ago, triaged_at: 2.minutes.ago,
                                         planned_at: 1.minute.ago)
      create(:agent_attempt, workflow:, status: :review_failed, phase: "planner")

      expect(workflow.phase).to eq("awaiting_approval")
    end

    it "una bocciatura sull'autopilot non maschera il lavoro che l'autopilot ha poi consegnato" do
      workflow = create(:agent_workflow, approved_at: 3.minutes.ago, autopilot_started_at: 2.minutes.ago,
                                         autopilot_completed_at: 1.minute.ago,
                                         candidate_verified_at: 1.minute.ago)
      create(:agent_attempt, workflow:, status: :review_failed, phase: "autopilot")

      expect(workflow.phase).to eq("awaiting_autopilot_approval")
    end

    it "una bocciatura su una fase ancora APERTA continua a bloccare" do
      workflow = create(:agent_workflow, triage_started_at: 1.minute.ago)
      create(:agent_attempt, workflow:, status: :review_failed, phase: "triage")

      expect(workflow.phase).to eq("review_blocked")
    end

    # Il tetto ai tentativi (CYRA-218) è ciò che dichiara ferma una lavorazione, e vale da sé: non deve
    # dipendere dal fatto che una delle bocciature risulti ancora aperta, o filtrandole si perderebbe la
    # riga dalla coda delle decisioni proprio mentre aspetta una persona.
    it "il tetto ai tentativi blocca anche quando ogni bocciatura è su una fase conclusa" do
      workflow = create(:agent_workflow, triage_started_at: 3.minutes.ago, triaged_at: 2.minutes.ago,
                                         planned_at: 1.minute.ago, blocked_at: Time.current,
                                         blocked_phase: "triage", blocked_kind: "attempt_limit")
      create(:agent_attempt, workflow:, status: :review_failed, phase: "triage")

      expect(workflow.phase).to eq("review_blocked")
    end
  end

  describe "#ready_execution_phase" do
    # I timestamp di un workflow reale si accumulano monotòni: ogni fixture setta la catena FINO al punto
    # testato (in produzione il claim/deliver non salta mai i timestamp intermedi). triage_requested_at è già
    # nella factory. Helper: catena cumulativa dei timestamp elencati.
    def through(*keys)
      keys.index_with { Time.current }
    end

    # workflow_state pronto → execution_phase canonico (PhaseProfile::PHASES), con catena realistica.
    ready_states = {
      "triage" => %i[triage_requested_at],
      "planner" => %i[triage_started_at triaged_at],
      "autopilot" => %i[triage_started_at triaged_at planned_at approved_at],
      "closer_staging" => %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at
                             autopilot_completed_at autopilot_approved_at],
      # CYRA-620 — la produzione si apre sulla PROVA, non sulla dichiarazione: `closer_staging_verified_at`
      # è il momento in cui il sistema ha visto il codice approvato atterrare sulla linea principale.
      "closer_production" => %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at
                               autopilot_completed_at autopilot_approved_at closer_staging_started_at
                               closer_staging_completed_at closer_staging_verified_at
                               closer_production_approved_at]
    }

    ready_states.each do |execution_phase, chain|
      it "restituisce #{execution_phase.inspect} quando il ticket è pronto per quella fase" do
        workflow = create(:agent_workflow, **through(*chain))

        expect(workflow.ready_execution_phase).to eq(execution_phase)
      end
    end

    it "restituisce nil per gli stati in corso o in attesa (nessuna fase reclamabile)" do
      expect(create(:agent_workflow, **through(:triage_started_at)).ready_execution_phase).to be_nil # triaging
      expect(create(:agent_workflow, **through(:triage_started_at, :triaged_at, :planned_at))
        .ready_execution_phase).to be_nil # awaiting_approval
      expect(create(:agent_workflow, **through(:triage_started_at, :triaged_at, :planned_at, :approved_at,
                                               :autopilot_started_at)).ready_execution_phase).to be_nil # autopilot in corso
      expect(create(:agent_workflow, **through(:triage_started_at, :triaged_at, :planned_at, :approved_at,
                                               :autopilot_started_at, :autopilot_completed_at))
        .ready_execution_phase).to be_nil # awaiting_autopilot_approval
    end

    # CYRA-504 — il tag stabile è l'unico passo irreversibile della catena, e fino a qui partiva da
    # solo: la fase diventava reclamabile nell'istante in cui lo staging finiva. Ora la prontezza
    # esige anche il via libera di una persona.
    context "con lo staging concluso" do
      let(:workflow) { create(:agent_workflow, :closer_staging_completed) }

      # CYRA-629 — quello che apre la strada alla produzione è la prova, non un pulsante.
      it "propone closer_production senza aspettare nessun via libera" do
        expect(workflow.ready_execution_phase).to eq("closer_production")
      end

      it "propone closer_production dopo l'approvazione" do
        workflow.update!(closer_production_approved_at: Time.current)

        expect(workflow.ready_execution_phase).to eq("closer_production")
      end

      it "resta ferma se l'approvazione arriva su una lavorazione bloccata" do
        workflow.update!(blocked_at: Time.current, blocked_phase: "closer_production", blocked_kind: "attempt_limit",
                         closer_production_approved_at: Time.current)

        expect(workflow.ready_execution_phase).to be_nil
      end
    end

    it "restituisce nil se annullato o completato anche con timestamp di fase presenti" do
      expect(create(:agent_workflow, **through(:triage_started_at, :triaged_at), cancelled_at: Time.current)
        .ready_execution_phase).to be_nil
      expect(create(:agent_workflow, **through(:triage_started_at, :triaged_at), completed_at: Time.current)
        .ready_execution_phase).to be_nil
    end

    # La bocciatura è del PLANNER (non il "triage" di default della factory): è quella che il piano mancante
    # lascia aperta, quindi #phase la vede ancora mentre la coda ripropone comunque la fase. Con una
    # bocciatura del triage il fixture direbbe un'altra cosa — quel triage è concluso (triaged_at) e non
    # blocca più niente (CYRA-280).
    it "resta reclamabile (planner) con un tentativo bocciato in review, mentre #phase è review_blocked" do
      workflow = create(:agent_workflow, **through(:triage_started_at, :triaged_at))
      create(:agent_attempt, workflow:, status: :review_failed, phase: "planner")

      expect(workflow.phase).to eq("review_blocked")
      expect(workflow.ready_execution_phase).to eq("planner")
    end

    # CYRA-218: il blocco è la guardia che ferma il ciclo di retry. Sta accanto a cancelled/completed
    # perché come loro è una proprietà del WORKFLOW che spegne OGNI fase, non solo quella bocciata:
    # riproporre il triage a un workflow fermo per un piano non convergente sarebbe la stessa corsa a
    # vuoto sotto un altro nome.
    it "non offre nessuna fase quando la lavorazione è bloccata, comunque sia messa la catena" do
      %i[triage_requested_at triaged_at approved_at autopilot_approved_at closer_staging_completed_at]
        .each do |last|
          chain = %i[triage_requested_at triage_started_at triaged_at planned_at approved_at
                     autopilot_started_at autopilot_completed_at autopilot_approved_at
                     closer_staging_started_at closer_staging_completed_at]
          workflow = create(:agent_workflow, **through(*chain.take(chain.index(last) + 1)),
                                             blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit")

          expect(workflow.ready_execution_phase).to be_nil
        end
    end

    describe "parità Ruby ⇄ SQL (READY_EXECUTION_PHASE_SQL)" do
      states = {
        "triage_queued" => %i[triage_requested_at],
        "triaging" => %i[triage_started_at],
        "planning" => %i[triage_started_at triaged_at],
        "awaiting_approval" => %i[triage_started_at triaged_at planned_at],
        "autopilot_queued" => %i[triage_started_at triaged_at planned_at approved_at],
        "autopilot" => %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at],
        "awaiting_autopilot_approval" => %i[triage_started_at triaged_at planned_at approved_at
                                           autopilot_started_at autopilot_completed_at],
        "closer_staging_queued" => %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at
                                     autopilot_completed_at autopilot_approved_at],
        "closer_staging" => %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at
                              autopilot_completed_at autopilot_approved_at closer_staging_started_at],
        # CYRA-650 — la combinazione di colonne resta valida e va provata; il nome della fase che le
        # corrispondeva non esiste più, quindi la riga si chiama per quello che è.
        "staging concluso, prova non ancora vista" => %i[triage_started_at triaged_at planned_at approved_at
                                            autopilot_started_at autopilot_completed_at autopilot_approved_at
                                            closer_staging_started_at closer_staging_completed_at],
        "closer_production_queued" => %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at
                                        autopilot_completed_at autopilot_approved_at closer_staging_started_at
                                        closer_staging_completed_at closer_production_approved_at],
        "closer_production" => %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at
                                 autopilot_completed_at autopilot_approved_at closer_staging_started_at
                                 closer_staging_completed_at closer_production_approved_at
                                 closer_production_started_at]
      }

      states.each do |label, chain|
        it "il CASE SQL coincide col metodo Ruby (#{label})" do
          workflow = create(:agent_workflow, **through(*chain))

          sql_value = Agents::Workflow.where(id: workflow.id)
                                      .pick(Arel.sql("(#{Agents::Workflow::READY_EXECUTION_PHASE_SQL})"))

          expect(sql_value).to eq(workflow.ready_execution_phase)
        end
      end

      it "il CASE SQL coincide col metodo Ruby su annullato/completato (entrambi nil)" do
        [ { cancelled_at: Time.current }, { closer_staging_completed_at: Time.current, closer_staging_verified_at: Time.current, completed_at: Time.current } ].each do |ts|
          workflow = create(:agent_workflow, **through(:triage_started_at, :triaged_at), **ts)
          sql_value = Agents::Workflow.where(id: workflow.id)
                                      .pick(Arel.sql("(#{Agents::Workflow::READY_EXECUTION_PHASE_SQL})"))
          expect(sql_value).to eq(workflow.ready_execution_phase)
        end
      end

      # La guardia del blocco vive in DUE posti (metodo Ruby e CASE SQL) e li usano due chiamanti diversi:
      # se divergono, la coda continua a servire una fase che il modello considera ferma — cioè il ciclo
      # infinito che CYRA-218 chiude, sopravvissuto nel solo percorso SQL.
      it "il CASE SQL coincide col metodo Ruby su una lavorazione bloccata (entrambi nil)" do
        workflow = create(:agent_workflow, **through(:triage_started_at, :triaged_at),
                                           blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit")

        sql_value = Agents::Workflow.where(id: workflow.id)
                                    .pick(Arel.sql("(#{Agents::Workflow::READY_EXECUTION_PHASE_SQL})"))

        expect(sql_value).to eq(workflow.ready_execution_phase)
        expect(sql_value).to be_nil
      end
    end
  end

  # CYRA-504 — prima di autorizzare la produzione serve sapere quale build è già in giro. Il tag sta
  # nel result dell'attempt (audit immutabile): il workflow non ha una colonna sua, e "l'ultima release
  # staging del progetto" con due lavorazioni in parallelo sarebbe il rilascio di un altro ticket.

  describe "#stalled_review_phase (CYRA-267)" do
    def through(*keys)
      keys.index_with { Time.current }
    end

    # Una bocciatura in review non muove i timestamp: la fase resta avviata e mai conclusa, quindi la coda
    # smette di proporla e nessuno la riapre (MarkStale pota solo gli orfani ancora `running`). È la fase da
    # riaprire perché la lavorazione riparta.
    it "è la fase bocciata dalla revisione che il claim ha tolto dalla coda" do
      workflow = create(:agent_workflow, **through(:triage_started_at))
      create(:agent_attempt, workflow:, phase: "triage", status: :review_failed)

      expect(workflow.ready_execution_phase).to be_nil
      expect(workflow.stalled_review_phase).to eq("triage")
    end

    # Il planner non ha un avvio dedicato: bocciato, resta comunque reclamabile e riparte da sé. Riaprire
    # non avrebbe nulla da azzerare, e offrirlo sarebbe un pulsante che finge.
    it "è nil quando la fase bocciata è comunque riproposta alla coda" do
      workflow = create(:agent_workflow, **through(:triage_started_at, :triaged_at))
      create(:agent_attempt, workflow:, phase: "planner", status: :review_failed)

      expect(workflow.ready_execution_phase).to eq("planner")
      expect(workflow.stalled_review_phase).to be_nil
    end

    it "è nil quando la fase bocciata è stata poi conclusa da un tentativo successivo" do
      workflow = create(:agent_workflow, **through(:triage_started_at, :triaged_at))
      create(:agent_attempt, workflow:, phase: "triage", status: :review_failed)

      expect(workflow.stalled_review_phase).to be_nil
    end

    # Gli attempt sono audit immutabile: una bocciatura vecchia resta in archivio anche quando la
    # lavorazione è andata avanti. Ferma è la fase PIÙ AVANZATA, non la prima che si incontra.
    it "sceglie la fase più avanzata quando la storia porta più bocciature" do
      workflow = create(:agent_workflow, **through(:triage_started_at, :triaged_at, :planned_at, :approved_at,
                                                   :autopilot_started_at))
      create(:agent_attempt, workflow:, phase: "triage", status: :review_failed)
      create(:agent_attempt, workflow:, phase: "autopilot", status: :review_failed)

      expect(workflow.stalled_review_phase).to eq("autopilot")
    end

    it "è nil su una lavorazione annullata o completata" do
      %i[cancelled_at completed_at].each do |terminal|
        workflow = create(:agent_workflow, **through(:triage_started_at), terminal => Time.current)
        create(:agent_attempt, workflow:, phase: "triage", status: :review_failed)

        expect(workflow.stalled_review_phase).to be_nil
      end
    end

    it "è nil senza bocciature, anche su una fase avviata e mai conclusa" do
      workflow = create(:agent_workflow, **through(:triage_started_at))

      expect(workflow.stalled_review_phase).to be_nil
    end

    # Dopo un riaccodo la fase viene riclaimata: lo start torna scritto e la vecchia bocciatura resta in
    # archivio, quindi senza questa guardia la fase risulterebbe di nuovo ferma. Riaprirla azzererebbe lo
    # start di un tentativo IN VOLO — un secondo host sullo stesso lavoro. Con un tentativo attivo la
    # lavorazione non è ferma: sta riprovando.
    %i[running awaiting_review].each do |status|
      it "è nil quando sulla stessa fase c'è già un tentativo #{status} (retry in volo)" do
        workflow = create(:agent_workflow, **through(:triage_started_at))
        create(:agent_attempt, workflow:, phase: "triage", status: :review_failed)
        create(:agent_attempt, workflow:, phase: "triage", status:)

        expect(workflow.stalled_review_phase).to be_nil
      end
    end

    it "resta ferma se il tentativo in volo è su un'altra fase" do
      workflow = create(:agent_workflow, **through(:triage_started_at))
      create(:agent_attempt, workflow:, phase: "triage", status: :review_failed)
      create(:agent_attempt, workflow:, phase: "planner", status: :running)

      expect(workflow.stalled_review_phase).to eq("triage")
    end

    # CYRA-317 — la coda delle approvazioni deve sapere su OGNI riga se la lavorazione è ferma o sta
    # riprovando da sola: chiederlo al metodo che carica gli attempt sarebbe due query per workflow,
    # cioè un N+1 in coda. Il gemello PURO prende le fasi già plucked in blocco e deve rispondere
    # sempre come il suo gemello impuro — se divergessero, la coda separerebbe le righe con una regola
    # e il pannello ne offrirebbe un'altra.
    describe "#stalled_review_phase_from (gemello puro)" do
      def assert_parity(workflow)
        failed = workflow.attempts.status_review_failed.distinct.pluck(:phase)
        open = workflow.attempts.where.not(status: Agents::Attempt::TERMINAL_STATUSES).distinct.pluck(:phase)

        expect(workflow.stalled_review_phase_from(failed, open)).to eq(workflow.stalled_review_phase)
      end

      it "coincide col gemello impuro su tutta la casistica" do
        stop = create(:agent_workflow, **through(:triage_started_at))
        create(:agent_attempt, workflow: stop, phase: "triage", status: :review_failed)
        assert_parity(stop)
        expect(stop.stalled_review_phase).to eq("triage")

        retry_later = create(:agent_workflow, **through(:triage_started_at, :triaged_at))
        create(:agent_attempt, workflow: retry_later, phase: "planner", status: :review_failed)
        assert_parity(retry_later)
        expect(retry_later.stalled_review_phase).to be_nil

        in_volo = create(:agent_workflow, **through(:triage_started_at))
        create(:agent_attempt, workflow: in_volo, phase: "triage", status: :review_failed)
        create(:agent_attempt, workflow: in_volo, phase: "triage", status: :running)
        assert_parity(in_volo)

        pulita = create(:agent_workflow, **through(:triage_started_at))
        assert_parity(pulita)

        annullata = create(:agent_workflow, **through(:triage_started_at), cancelled_at: Time.current)
        create(:agent_attempt, workflow: annullata, phase: "triage", status: :review_failed)
        assert_parity(annullata)
      end
    end
  end

  describe "#reopen_execution_phase! (CYRA-212)" do
    # Il claim scrive <fase>_started_at (mark_workflow_started!); se l'host muore a metà, <fase>ed_at non
    # arriva mai e READY_EXECUTION_PHASE_SQL smette di proporre la fase → il ticket sparisce dalla coda.
    # Riaprire azzera lo start così il ticket rientra in coda. Catena cumulativa dei timestamp elencati.
    def through(*keys)
      keys.index_with { Time.current }
    end

    # Ogni fase con un proprio avvio: catena FINO all'avvio (mai concluso) → nessuna fase pronta, poi
    # reopen la rende di nuovo pronta.
    {
      "triage" => { chain: %i[triage_started_at], started: :triage_started_at },
      "autopilot" => { chain: %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at],
                       started: :autopilot_started_at },
      "closer_staging" => { chain: %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at
                                      autopilot_completed_at autopilot_approved_at closer_staging_started_at],
                            started: :closer_staging_started_at },
      # closer_production_approved_at fa parte della catena realistica (CYRA-504): una produzione che
      # è stata claimata è per forza una produzione che qualcuno aveva autorizzato, e senza il timbro
      # la riapertura non rimetterebbe la fase in coda.
      "closer_production" => { chain: %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at
                                         autopilot_completed_at autopilot_approved_at closer_staging_started_at
                                         closer_staging_completed_at closer_staging_verified_at
                                         closer_production_approved_at closer_production_started_at],
                               started: :closer_production_started_at }
    }.each do |phase, config|
      it "riapre #{phase}: azzera lo start di una fase avviata e mai conclusa e la rende di nuovo pronta" do
        workflow = create(:agent_workflow, **through(*config[:chain]))
        expect(workflow.ready_execution_phase).to be_nil

        expect(workflow.reopen_execution_phase!(phase)).to be true
        expect(workflow.reload.public_send(config[:started])).to be_nil
        expect(workflow.ready_execution_phase).to eq(phase)
      end
    end

    it "azzera anche l'attribuzione host-first della fase riaperta" do
      host = create(:agent_host)
      account = host.service_account
      workflow = create(:agent_workflow, **through(:triage_started_at),
                                         triage_by_host: host, triage_by_service_account: account)

      expect(workflow.reopen_execution_phase!("triage")).to be true
      workflow.reload
      expect(workflow.triage_by_host_id).to be_nil
      expect(workflow.triage_by_service_account_id).to be_nil
    end

    it "non riapre una fase già conclusa (marcatore di completamento presente)" do
      workflow = create(:agent_workflow, **through(:triage_started_at, :triaged_at))

      expect(workflow.reopen_execution_phase!("triage")).to be false
      expect(workflow.reload.triage_started_at).to be_present
    end

    it "non riapre una fase mai avviata" do
      workflow = create(:agent_workflow, **through(:triage_requested_at))

      expect(workflow.reopen_execution_phase!("triage")).to be false
    end

    it "è un no-op su un workflow annullato o completato" do
      cancelled = create(:agent_workflow, **through(:triage_started_at), cancelled_at: Time.current)
      completed = create(:agent_workflow, **through(:triage_started_at), completed_at: Time.current)

      expect(cancelled.reopen_execution_phase!("triage")).to be false
      expect(completed.reopen_execution_phase!("triage")).to be false
    end
  end

  describe "#send_phase_back_to_work!" do
    # Gemello di #reopen_execution_phase!, per il caso in cui quello si rifiuta di agire: lì la fase è
    # interrotta a metà (`done` nil), qui è CONCLUSA e una persona ha detto di rifarla. Senza, un rifiuto
    # lasciava il ticket in un vicolo cieco — fase conclusa e non approvata, quindi né riproposta dalla
    # coda né segnalata come ferma, e nell'interfaccia nessuna azione.
    def through(*keys)
      keys.index_with { Time.current }
    end

    let(:autopilot_done) do
      %i[triage_started_at triaged_at planned_at approved_at autopilot_started_at autopilot_completed_at]
    end

    it "rimanda al lavoro una fase conclusa: azzera avvio e conclusione, e la coda torna a proporla" do
      workflow = create(:agent_workflow, **through(*autopilot_done))
      expect(workflow.ready_execution_phase).to be_nil

      expect(workflow.send_phase_back_to_work!("autopilot")).to be true
      workflow.reload
      expect(workflow.autopilot_started_at).to be_nil
      expect(workflow.autopilot_completed_at).to be_nil
      expect(workflow.ready_execution_phase).to eq("autopilot")
    end

    it "azzera anche l'attribuzione host-first della fase" do
      host = create(:agent_host)
      workflow = create(:agent_workflow, **through(*autopilot_done),
                                         autopilot_by_host: host, autopilot_by_service_account: host.service_account)

      expect(workflow.send_phase_back_to_work!("autopilot")).to be true
      workflow.reload
      expect(workflow.autopilot_by_host_id).to be_nil
      expect(workflow.autopilot_by_service_account_id).to be_nil
    end

    it "vale anche su una fase avviata e non ancora conclusa" do
      workflow = create(:agent_workflow, **through(:triage_started_at))

      expect(workflow.send_phase_back_to_work!("triage")).to be true
      expect(workflow.reload.triage_started_at).to be_nil
    end

    it "non rimanda indietro una fase mai avviata" do
      workflow = create(:agent_workflow, **through(:triage_requested_at))

      expect(workflow.send_phase_back_to_work!("triage")).to be false
    end

    it "è un no-op su un workflow annullato o completato" do
      cancelled = create(:agent_workflow, **through(*autopilot_done), cancelled_at: Time.current)
      completed = create(:agent_workflow, **through(*autopilot_done), completed_at: Time.current)

      expect(cancelled.send_phase_back_to_work!("autopilot")).to be false
      expect(completed.send_phase_back_to_work!("autopilot")).to be false
    end

    it "ignora una fase che non esiste" do
      workflow = create(:agent_workflow, **through(:triage_started_at))

      expect(workflow.send_phase_back_to_work!("planner")).to be false
      expect(workflow.send_phase_back_to_work!("inventata")).to be false
    end

    it "è un no-op per il planner (nessun avvio dedicato: torna in coda alla scadenza del lease)" do
      workflow = create(:agent_workflow, **through(:triage_started_at, :triaged_at))

      expect(workflow.reopen_execution_phase!("planner")).to be false
      expect(workflow.reload.ready_execution_phase).to eq("planner")
    end

    it "è un no-op per una fase ignota" do
      workflow = create(:agent_workflow, **through(:triage_started_at))

      expect(workflow.reopen_execution_phase!("bogus")).to be false
    end
  end

  describe "#body_locked?" do
    it "blocca dal claim di triage fino a completamento o annullamento" do
      workflow = create(:agent_workflow, triage_requested_at: Time.current)
      expect(workflow.body_locked?).to be false

      workflow.update!(triage_started_at: Time.current)
      expect(workflow.body_locked?).to be true

      workflow.update!(cancelled_at: Time.current)
      expect(workflow.body_locked?).to be false
    end
  end

  # CYRA-604 — la lavorazione punta alla riga del registro che sta guardando, e quella scelta si fa
  # una volta sola: puntarne un'altra cancellerebbe il filo che lega la decisione alla prova.
  describe "review_candidate" do
    let(:organization) { create(:organization) }
    let(:workflow) { create(:agent_workflow, organization:) }

    it "si aggancia la prima volta" do
      riga = create(:agent_delivery_candidate, workflow:, organization:)

      expect { workflow.update!(review_candidate: riga) }.not_to raise_error
      expect(workflow.reload.review_candidate_id).to eq(riga.id)
    end

    it "non salta da una riga all'altra senza azzerare in mezzo" do
      prima = create(:agent_delivery_candidate, workflow:, organization:)
      poi = create(:agent_delivery_candidate, workflow:, organization:)
      workflow.update!(review_candidate: prima)

      expect { workflow.reload.update!(review_candidate: poi) }
        .to raise_error(ActiveRecord::ReadOnlyRecord, /si azzera prima questa/)
    end

    # CYRA-617 — il codice cambia dopo il controllo: la verifica si azzera e il sistema va a guardare
    # il codice nuovo. La prova non si perde — è la RIGA, che resta in archivio immutabile: questo è
    # solo il puntatore a quella che si sta guardando adesso.
    it "si sposta passando dal vuoto, e la riga di prima resta in archivio" do
      prima = create(:agent_delivery_candidate, :verified_passing, workflow:, organization:)
      poi = create(:agent_delivery_candidate, workflow:, organization:)
      workflow.update!(review_candidate: prima)

      expect do
        workflow.reload.update!(review_candidate: nil)
        workflow.reload.update!(review_candidate: poi)
      end.not_to raise_error

      expect(workflow.reload.review_candidate_id).to eq(poi.id)
      expect(Agents::DeliveryCandidate.find(prima.id)).to be_state_verified_passing
    end

    # Riscrivere lo STESSO valore non è spostare niente: un salvataggio che ripassa di lì non deve
    # far esplodere la lavorazione.
    it "tollera che le venga riscritto lo stesso valore" do
      riga = create(:agent_delivery_candidate, workflow:, organization:)
      workflow.update!(review_candidate: riga)

      expect { workflow.reload.update!(review_candidate_id: riga.id) }.not_to raise_error
    end

    # La chiave esterna copre «riga inesistente»; questo copre «riga di un'altra lavorazione», che
    # nessun vincolo di database sa vedere.
    it "rifiuta la riga di un'altra lavorazione" do
      altrove = create(:agent_delivery_candidate, workflow: create(:agent_workflow, organization:), organization:)

      workflow.review_candidate = altrove

      expect(workflow).not_to be_valid
      expect(workflow.errors[:review_candidate_id]).to include(/non è una verifica di questa lavorazione/)
    end

    it "non usa attr_readonly, che bloccherebbe l'aggancio stesso" do
      expect(described_class.readonly_attributes).not_to include("review_candidate_id")
    end
  end
  # CYRA-613 — «finita, in un modo o nell'altro» stava scritta in tre punti diversi. Tre copie della
  # stessa condizione divergono il giorno in cui una impara qualcosa e le altre no.
  describe "#terminal?" do
    it "è vera solo su una lavorazione conclusa o annullata" do
      expect(create(:agent_workflow, completed_at: Time.current)).to be_terminal
      expect(create(:agent_workflow, cancelled_at: Time.current)).to be_terminal
      expect(create(:agent_workflow)).not_to be_terminal
      expect(create(:agent_workflow, triage_started_at: Time.current)).not_to be_terminal
    end

    # NON è il contrario di `work_in_progress?`, ed è la differenza che tiene aperta la strada di chi
    # lavora a mano: una lavorazione mai avviata non è né in corso né finita.
    it "una lavorazione mai avviata non è né in corso né finita" do
      workflow = create(:agent_workflow, triage_started_at: nil)

      expect(workflow.terminal?).to be(false)
      expect(workflow.work_in_progress?).to be(false)
    end
  end
  # CYRA-615 — mentre il sistema guarda la proposta, la lavorazione ha un nome suo. Prima cadeva su
  # «autopilot», cioè si raccontava come lavoro che l'agente sta ancora scrivendo: chi apriva la
  # scheda leggeva una cosa che non stava succedendo.
  describe "#phase mentre il sistema controlla la proposta" do
    it "ha un nome suo, e non è quello del lavoro dell'agente" do
      workflow = create(:agent_workflow, approved_at: 2.minutes.ago, autopilot_started_at: 1.minute.ago,
                                         autopilot_completed_at: Time.current, candidate_verified_at: nil)

      expect(workflow.phase).to eq("verifying_candidate")
      expect(Agents::Workflows::PhaseResolver.phase(workflow, Set.new)).to eq("verifying_candidate")
    end

    # Non chiede niente: nell'elenco è lavoro in corso, non una decisione che aspetta.
    it "non è una fase che aspetta una persona" do
      expect(Agents::Workflows::PhaseResolver::HUMAN_GATED_PHASES).not_to include("verifying_candidate")
      expect(Agents::Workflows::PhaseResolver.stage("verifying_candidate")).to eq("in_progress")
    end

    # Un blocco vince comunque: fermarsi mentre il sistema controlla non deve leggersi come lavoro
    # che va avanti da solo.
    it "un blocco resta visibile anche qui" do
      workflow = create(:agent_workflow, approved_at: 2.minutes.ago, autopilot_started_at: 1.minute.ago,
                                         autopilot_completed_at: Time.current, blocked_at: Time.current,
                                         blocked_phase: "autopilot", blocked_kind: "candidate_check")

      expect(workflow.phase).to eq("review_blocked")
    end
  end
  # CYRA-618 — il numero che si legge dev'essere IL numero che ha fatto scattare la fermata.
  #
  # Prima la scheda contava solo le bocciature della revisione, mentre il tetto conta anche i giri
  # morti: su una lavorazione fermata da due host spenti la frase usciva «0 volte di fila», nel punto
  # esatto in cui qualcuno deve decidere — e chi leggeva premeva «Riprova» sullo stesso giro già
  # fallito due volte.
  describe "#stopped_failures" do
    let(:organization) { create(:organization) }
    let(:workflow) do
      create(:agent_workflow, organization:, triage_started_at: Time.current, blocked_at: Time.current,
                              blocked_phase: "triage", blocked_kind: "attempt_limit")
    end

    def tentativo(status)
      create(:agent_attempt, workflow:, organization:, phase: "triage", status:)
    end

    it "conta anche i giri morti, non solo le bocciature della revisione" do
      tentativo(:review_failed)
      tentativo(:failed)
      tentativo(:stale)

      expect(workflow.stopped_failures).to eq(3)
    end

    it "non conta i tentativi di un'altra fase né quelli riusciti" do
      tentativo(:review_failed)
      create(:agent_attempt, workflow:, organization:, phase: "planner", status: :failed)
      tentativo(:approved)

      expect(workflow.stopped_failures).to eq(1)
    end

    # Solo dall'ultimo sblocco in poi: gli attempt sono archivio, e contarli tutti direbbe un numero
    # più alto del tetto che ha fatto scattare la fermata.
    it "conta solo dall'ultimo sblocco in poi" do
      # Il tentativo terminale è audit immutabile: la data si mette alla nascita, non dopo.
      create(:agent_attempt, workflow:, organization:, phase: "triage", status: :failed,
                             created_at: 2.hours.ago)
      workflow.update!(review_budget_from: 1.hour.ago)
      tentativo(:failed)

      expect(workflow.stopped_failures).to eq(1)
    end

    # Chi ha già gli attempt in mano non deve fare una query in più per contarli.
    it "usa l'elenco che gli viene passato, quando c'è" do
      tentativo(:failed)

      expect(workflow.stopped_failures(workflow.attempts.to_a)).to eq(1)
    end
  end
  # CYRA-675 — la regola di «si può ancora chiedere se serve». Sta sul modello e non nella pagina
  # perché la leggono in tre: il pannello della home, la scheda Automazione e Workflows::Reassess,
  # che la rilegge sotto lock. Tre copie divergono al primo stato nuovo.
  describe "#reassessable?" do
    let(:workflow) { create(:agent_workflow, triage_requested_at: 2.days.ago) }

    it "vale mentre il lavoro è ancora da pianificare" do
      expect(workflow.phase).to eq("triage_queued")
      expect(workflow).to be_reassessable

      workflow.update!(triage_started_at: 1.day.ago, triaged_at: 12.hours.ago)
      expect(workflow.phase).to eq("planning")
      expect(workflow).to be_reassessable
    end

    it "vale sul piano che aspetta un sì" do
      workflow.update!(triage_started_at: 1.day.ago, triaged_at: 12.hours.ago, planned_at: 1.hour.ago)

      expect(workflow.phase).to eq("awaiting_approval")
      expect(workflow).to be_reassessable
    end

    # È il caso della pila delle decisioni: la pianificazione bocciata fino al tetto. Qui la fase
    # ferma NON si deduce dagli attempt — il planner non ha un avvio dedicato e non compare mai fra
    # le fasi ferme — e leggendo solo quelli il pulsante spariva proprio dove serve.
    it "vale su una pianificazione ferma per tetto di revisione" do
      workflow.update!(triage_started_at: 1.day.ago, triaged_at: 12.hours.ago,
                       blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit",
                       blocked_reason: "La revisione ha bocciato planner 2 volte su 2")

      expect(workflow.phase).to eq("review_blocked")
      expect(workflow).to be_reassessable
    end

    it "non vale su un fermo avvenuto dopo la pianificazione" do
      workflow.update!(triage_started_at: 1.day.ago, triaged_at: 12.hours.ago, planned_at: 6.hours.ago,
                       approved_at: 5.hours.ago, autopilot_started_at: 4.hours.ago,
                       blocked_at: Time.current, blocked_phase: "autopilot", blocked_kind: "attempt_limit",
                       blocked_reason: "tetto tentativi")

      expect(workflow.phase).to eq("review_blocked")
      expect(workflow).not_to be_reassessable
    end

    it "non vale da quando il codice lo scrive la macchina in poi" do
      workflow.update!(triage_started_at: 1.day.ago, triaged_at: 12.hours.ago, planned_at: 6.hours.ago,
                       approved_at: 5.hours.ago)
      expect(workflow.phase).to eq("autopilot_queued")
      expect(workflow).not_to be_reassessable

      workflow.update!(autopilot_started_at: 4.hours.ago, autopilot_completed_at: 3.hours.ago,
                       candidate_verified_at: 2.hours.ago)
      expect(workflow.phase).to eq("awaiting_autopilot_approval")
      expect(workflow).not_to be_reassessable
    end

    it "non vale su una lavorazione chiusa o annullata" do
      workflow.update!(completed_at: Time.current)
      expect(workflow).not_to be_reassessable

      workflow.update!(completed_at: nil, cancelled_at: Time.current, cancellation_reason: "basta")
      expect(workflow).not_to be_reassessable
    end
  end

  # CYRA-689 — la coda delle approvazioni e l'elenco delle lavorazioni in volo risolvevano l'agente
  # con due catene di ricaduta diverse: lo stesso workflow diceva «nessuno» su una pagina e il nome
  # della macchina sull'altra. La catena vive qui, in un posto solo.
  describe "#attributed_host_id" do
    it "sceglie la macchina della fase più avanzata che ne ha registrata una" do
      host_ids = Array.new(3) { create(:agent_host).id }

      workflow = create(:agent_workflow, triage_by_host_id: host_ids[0])
      expect(workflow.attributed_host_id).to eq(host_ids[0])

      workflow.update!(planned_by_host_id: host_ids[1])
      expect(workflow.attributed_host_id).to eq(host_ids[1])

      workflow.update!(closer_production_by_host_id: host_ids[2])
      expect(workflow.attributed_host_id).to eq(host_ids[2])
    end

    it "resta nil quando nessuna fase ha registrato una macchina" do
      expect(create(:agent_workflow).attributed_host_id).to be_nil
    end
  end
end
