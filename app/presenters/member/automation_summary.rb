# frozen_string_literal: true

module Member
  # Le tre righe in testa alla scheda Automazione (CYRA-384): cosa ha fatto, perché si è fermata,
  # cosa serve da chi legge. La scheda apriva su decine di tentativi quasi identici e su un testo
  # lungo, e chi doveva approvare o rifiutare non trovava mai la riga che conta.
  #
  # OGNI riga nasce da campi strutturati — la fase del workflow, lo status dei tentativi, il numero di
  # domande aperte — e mai da euristiche sul testo libero consegnato dalla macchina. È il rischio
  # scritto nel ticket: una sintesi ricavata a naso può dire il falso proprio nel punto in cui si
  # decide, ed è peggio del registro che sostituisce.
  #
  # Non tocca il database: riceve gli attempt già caricati dal controller (load_automation_tab).
  class AutomationSummary
    # Fase del workflow → chiave della riga «perché si è fermata». Le fasi che non sono un'attesa
    # dicono che NON è ferma: è l'informazione che evita di intervenire su qualcosa che si sta già
    # risolvendo da solo.
    STOPPED_KEYS = {
      "inactive" => "inactive",
      "triage_queued" => "queued", "autopilot_queued" => "queued",
      "closer_staging_queued" => "queued", "closer_production_queued" => "queued",
      "triaging" => "working", "planning" => "working", "autopilot" => "working",
      # CYRA-615 — «sto controllando» ha una frase sua: dirlo «working» come gli altri nasconderebbe
      # proprio la cosa nuova, cioe' che qualcuno sta guardando la proposta al posto tuo.
      "verifying_candidate" => "verifying_candidate",
      "verifying_staging" => "verifying_staging",
      # CYRA-624 — anche «sto guardando se il rilascio è in piedi» ha una frase sua: senza, cadrebbe
      # su «ci sta lavorando adesso», che è falso — non ci sta lavorando nessuno, si sta guardando.
      "awaiting_production_proof" => "awaiting_production_proof",
      "closer_staging" => "working", "closer_production" => "working",
      "awaiting_approval" => "awaiting_approval",
      "awaiting_autopilot_approval" => "awaiting_autopilot_approval",
      "completed" => "completed"
    }.freeze

    # Fase del workflow → cosa serve da una persona. Fuori da questa mappa la lavorazione va avanti da
    # sola e lo si dice: «niente» è una risposta, «nessuna riga» è un dubbio.
    NEEDS_KEYS = {
      "awaiting_approval" => "approve_plan",
      "awaiting_autopilot_approval" => "review_delivery",
      "review_blocked" => "unblock",
      # CYRA-876 — a finished workflow does not «carry on by itself»: saying so under «Annullato» read as a contradiction.
      "cancelled" => "finished",
      "completed" => "finished"
    }.freeze

    # Un tentativo CONCLUSO: gli altri stanno ancora girando, e «cosa ha fatto» deve restare l'ultimo
    # passo finito — non quello in corso, che non ha ancora fatto niente.
    FINISHED_STATUSES = %w[approved rejected review_failed failed stale cancelled].freeze

    # CYRA-623 — `blocking_codes` sono i codici dei prerequisiti che trattengono il ticket in coda
    # (solo quelli che chi guarda può vedere) e `blocking_count` quanti sono davvero: con un
    # prerequisito su un progetto fuori scope il conteggio c'è e il codice no. Li compone il
    # controller dal cancello: questa classe non tocca il database.
    # CYRA-626 — `retry_hint` è quello che il sistema non riesce a leggere e quando ci riprova,
    # letto dalla riga che lo ha scritto. Lo compone il controller: qui non si tocca il database.
    def initialize(workflow:, attempts:, decides:, pending_questions: 0, cto_name: nil,
                   blocking_codes: [], blocking_count: 0, retry_hint: nil)
      @workflow = workflow
      @attempts = attempts
      @decides = decides
      @pending_questions = pending_questions.to_i
      @cto_name = cto_name
      @blocking_codes = Array(blocking_codes)
      @blocking_count = blocking_count.to_i
      @retry_hint = retry_hint
    end

    def done
      attempt = @attempts.reverse_each.find { |candidate| FINISHED_STATUSES.include?(candidate.status) }
      return t("done.none") if attempt.nil?

      t("done.last", phase: execution_phase_label(attempt.phase),
                     outcome: outcome_label(attempt.status),
                     ago: ActionController::Base.helpers.time_ago_in_words(attempt.finished_at || attempt.started_at))
    end

    def stopped
      return cancelled_line if @workflow.cancelled_at?
      return blocked_line if @workflow.phase == "review_blocked"
      # An open question holds the ticket out of the queue: «waits for a free machine» would be false.
      return t("stopped.waiting_answer", count: @pending_questions) if @pending_questions.positive?
      # Prima della mappa delle fasi: la fase dice «in coda», ma da quella coda il ticket non esce
      # finché il prerequisito non è a posto. Chi legge starebbe aspettando una cosa che non succede.
      return dependencies_line if @blocking_count.positive?
      # CYRA-626 — l'elenco e la scheda raccontano la stessa storia: se il sistema non riesce a
      # leggere, lo dicono tutti e due, con lo stesso guasto e la stessa ora.
      return retry_hint_line if @retry_hint
      # CYRA-682 — stessa ragione della riga dei prerequisiti qui sopra: la fase dice «in coda», ma da
      # quella coda il ticket non esce finché il progetto non dichiara come si prova che un rilascio è
      # riuscito. Senza questa riga il ticket sparirebbe dalla coda in silenzio e la scheda
      # continuerebbe a raccontarlo come «aspetta una macchina libera», che è falso: non partirà mai.
      return missing_release_probe_line if missing_release_probe?
      return production_queue_line if @workflow.phase == "closer_production_queued"

      # CYRA-626 — `fetch` senza ripiego: una fase nuova senza riga propria fa rosso qui invece di
      # raccontarsi come «ci sta lavorando adesso», che su una fase di attesa è falso.
      t("stopped.#{STOPPED_KEYS.fetch(@workflow.phase)}")
    end

    # Il guasto e l'ora vengono dalla riga che il sistema ha scritto, non ricomposti qui: due frasi
    # composte in due punti diversi dicono la stessa cosa finché una delle due non cambia.
    def retry_hint_line
      t("stopped.retry_hint", code: @retry_hint.code, at: I18n.l(@retry_hint.at, format: :short))
    end

    # CYRA-682 — la lavorazione è pronta per una fase che TOCCA il repository, ma il vincolo congelato
    # all'approvazione non c'è: manca la prova di rilascio sul progetto, quindi la macchina non può
    # sapere dove aprire la proposta né quando dirsi finita, e la coda non la propone.
    #
    # Legge il piano congelato già caricato dal controller, come tutto il resto di questa classe: qui
    # non si tocca il database.
    def missing_release_probe?
      phase = @workflow.ready_execution_phase
      return false unless phase && ::Agents::PhaseProfile.fetch(phase).write_access?

      @workflow.frozen_plan&.candidate_items.blank?
    end

    def missing_release_probe_line = t("stopped.missing_release_probe")

    # Il codice del prerequisito quando chi guarda può vederlo; altrimenti il solo fatto. Un ticket di
    # un progetto fuori scope non si nomina: sarebbe una fuga di informazione travestita da aiuto.
    def dependencies_line
      return t("stopped.dependencies_anonymous") if @blocking_codes.empty?

      t("stopped.dependencies", codes: @blocking_codes.to_sentence(locale: I18n.locale))
    end

    # Le domande vengono prima di tutto: finché una resta senza risposta la lavorazione non riparte,
    # e chiedere di approvare un piano su cui la macchina ha ancora un dubbio è chiedere la cosa
    # sbagliata.
    def needs
      return t("needs.answer_questions", count: @pending_questions) if @pending_questions.positive?

      key = NEEDS_KEYS[@workflow.phase]
      return t("needs.nothing") if key.nil? || retrying?
      return t("needs.#{key}") if @decides || key == "finished"
      return t("needs.decided_by", name: @cto_name) if @cto_name.present?

      t("needs.no_decider")
    end

    # Halted for real: the row keeps «Perché si è fermata». Otherwise it reads «A che punto è».
    def halted?
      return true if @workflow.cancelled_at? || @workflow.blocked_at? || @blocking_count.positive?
      return true if @pending_questions.positive?
      return true if %w[awaiting_approval awaiting_autopilot_approval].include?(@workflow.phase)

      missing_release_probe?
    end

    # The «what you need» row is highlighted only when a person has to act: an open question, or a
    # decision that belongs to the one reading.
    def needs_person?
      return true if @pending_questions.positive?

      key = NEEDS_KEYS[@workflow.phase]
      key.present? && key != "finished" && !retrying? && @decides
    end

    # CYRA-877 — a rejected step with budget left is already being redone by the queue: nothing to decide, and
    # no restart button exists. Only `blocked_at` means the work stopped and calls a person.
    def retrying? = @workflow.phase == "review_blocked" && !@workflow.blocked_at?

    # La decisione da mettere in evidenza, o nil. Il ticket chiedeva una CTA che cambiasse con lo
    # stato; la risposta del cliente (2026-08-17) l'ha ristretta ad approva/rifiuta — «un bottone che
    # cambia significato riga per riga si preme per sbaglio». Le altre uscite (riprova, ferma la
    # lavorazione) restano dove sono già, col loro peso.
    def decision
      return nil unless @decides && @pending_questions.zero?

      :plan if @workflow.phase == "awaiting_approval"
    end

    private

    # CYRA-595 — «aspetta una macchina libera» e «aspetta che finisca un altro rilascio» sono due
    # attese diverse: la prima dura minuti e non dipende da niente, la seconda dipende da un lavoro
    # preciso che si può andare a guardare. Dirle con la stessa frase lascia chi legge senza il
    # dato che serve.
    #
    # Il motivo si calcola qui e non si salva da nessuna parte: una colonna sopravviverebbe alla
    # causa, e mostrerebbe «aspetta il rilascio di X» quando X è finito da un pezzo.
    def production_queue_line
      hold = ::Agents::Workflows::ProductionHold.reason(@workflow, now: Time.current)
      return production_hold_line(hold) if hold

      holder = ::Agents::Workflows::ProductionLock.holder(project: @workflow.ticket.project,
                                                         except: @workflow)
      return t("stopped.queued") if holder.nil?

      code = holder.ticket.code if @decides
      return t("stopped.production_busy_anonymous") if code.blank?

      t("stopped.production_busy", code: code)
    end

    # CYRA-871 — il freno prima della produzione: due ore di prova dello staging, poi niente errori
    # nuovi ancora aperti. Il titolo dell'errore solo a chi decide, come il codice del ticket qui sopra.
    def production_hold_line(hold)
      if hold[:reason] == "staging_soak"
        return t("stopped.production_soak", at: I18n.l(hold[:until], format: :short))
      end
      return t("stopped.production_staging_error_anonymous") unless @decides

      t("stopped.production_staging_error", title: Errors::Group.find(hold[:error_group_id]).title)
    end

    def cancelled_line
      reason = @workflow.cancellation_reason.presence
      reason ? t("stopped.cancelled", reason:) : t("stopped.cancelled_no_reason")
    end

    # Ferma davvero (blocked_at) vs. ancora in corsa: una bocciatura sola con budget aperto NON è una
    # lavorazione ferma, e dirla ferma spinge a intervenire su qualcosa che si sta già risolvendo.
    # Il conteggio è lo STESSO del banner più sotto — solo dall'ultimo sblocco in poi, altrimenti
    # direbbe un numero più alto del tetto che ha fatto scattare il blocco.
    def blocked_line
      return t("stopped.retrying") unless @workflow.blocked_at?
      # CYRA-598 — quando a fermarsi è stata la macchina, la frase del tetto è falsa due volte:
      # nomina la revisione, che non c'entra, e mostra un conteggio che è ZERO — una consegna che
      # dichiara un blocco è valida e si chiude approved, quindi di bocciature non ne produce
      # nessuna. Sarebbe uscito «La revisione ha respinto autopilot 0 volte di fila», nel punto
      # esatto in cui qualcuno deve decidere. Qui si riporta il motivo dell'agente, parola per parola.
      return t("stopped.agent_blocked", phase: execution_phase_label(@workflow.blocked_phase),
                                        reason: agent_reason) if @workflow.blocked_kind == "agent_blocked"

      # CYRA-614 — il sistema è andato a guardare la proposta e ha trovato qualcosa che non va. Anche
      # qui la frase del tetto sarebbe falsa due volte: nomina la revisione, che non c'entra, e conta
      # bocciature che sono zero — la consegna era valida.
      if @workflow.blocked_kind == "candidate_check"
        return t("stopped.candidate_check", reason: agent_reason)
      end

      # CYRA-624 — il rilascio non si è visto in piedi. È un momento diverso dal controllo della
      # proposta e da una revisione bocciata, e chiamarlo con le loro parole manderebbe a cercare nel
      # posto sbagliato.
      return t("stopped.release_probe", reason: agent_reason) if @workflow.blocked_kind == "release_probe"
      return t("stopped.held_by_person", name: @workflow.held_by_name) if @workflow.held_by_name

      t("stopped.blocked", phase: execution_phase_label(@workflow.blocked_phase), count: blocked_failures)
    end

    # Il motivo arriva dall'agente e si mostra com'è: riscriverlo vorrebbe dire interpretarlo, e chi
    # deve decidere ha bisogno di quello che la macchina ha davvero detto. La ripulitura del prefisso
    # tecnico vive sul modello, così la riga di sintesi e il banner della scheda non possono
    # divergere.
    def agent_reason
      @workflow.agent_block_reason || t("stopped.agent_blocked_no_reason")
    end

    # CYRA-618 — la regola sta sul workflow, in un punto solo: due calcoli identici in due file
    # divergono, e il primo a divergere è proprio il numero che chi legge usa per decidere.
    def blocked_failures = @workflow.stopped_failures(@attempts)

    def execution_phase_label(phase)
      I18n.t("member.tickets.automation.execution_phase.#{phase}", default: phase.to_s.humanize)
    end

    def outcome_label(status)
      key, = Member::AutomationHelper::ATTEMPT_OUTCOMES.fetch(status.to_s, %w[running])
      I18n.t("member.tickets.automation.steps.outcome.#{key}")
    end

    def t(key, **) = I18n.t("member.tickets.automation.summary.#{key}", **)
  end
end
