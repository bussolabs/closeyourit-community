# frozen_string_literal: true

module Member
  # A CHE PUNTO è la lavorazione nel suo insieme: da quando aspetta in coda, perché si è fermata, cosa
  # ha detto chi l'ha revisionata e cosa ha dichiarato di aver fatto. Il nil è sempre un gate: dove non
  # c'è un'ora l'attesa non è mai cominciata, e non si promette un avvio (CYRA-742).
  module AutomationWorkflowHelper
    # Timestamp d'ingresso in coda di ogni fase in attesa (CYRA-410). La colonna è sempre il marcatore
    # che HA MESSO in coda quella fase — quello che #phase legge per dichiararla `*_queued`: la
    # richiesta di valutazione per il triage, l'approvazione del piano per l'autopilot, e così via.
    # Non `created_at` del workflow, che su una coda successiva alla prima direbbe un'ora vecchia di
    # giorni.
    QUEUED_PHASE_TIMESTAMPS = {
      "triage_queued" => :triage_requested_at,
      "autopilot_queued" => :approved_at,
      "closer_staging_queued" => :autopilot_approved_at,
      "closer_production_queued" => :closer_staging_completed_at
    }.freeze

    # Nome italiano della fase di ESECUZIONE (Agents::Attempt#phase): vocabolario diverso da quello
    # del workflow, dove tre nomi su cinque coincidono e vogliono dire un'altra cosa.
    # Il motivo scritto dall'agente, pronto da leggere. Il ripiego non è vuoto di proposito: un
    # banner che dice «Ferma — serve una decisione» e poi non dice niente è peggio di uno che ammette
    # che il motivo non è stato scritto.
    def automation_agent_block_reason(workflow)
      workflow.agent_block_reason || t("member.tickets.automation.stopped.agent_blocked_no_reason")
    end

    # Da quando la lavorazione aspetta, o nil se non è in coda. Il nil è il gate dello stato vuoto:
    # dove c'è un'ora, l'attesa è normale e si dice; dove non c'è, la lavorazione non è partita davvero
    # e il testo neutro resta quello giusto (mai promettere un avvio che non arriverà).
    def automation_queued_since(workflow)
      column = QUEUED_PHASE_TIMESTAMPS[workflow.phase]
      column && workflow.public_send(column)
    end

    # Verdetto della revisione incrociata: nil quando non c'è stata (un tentativo interrotto non arriva
    # mai alla revisione, e mostrarne una vuota farebbe sembrare che qualcuno abbia giudicato).
    def automation_review(attempt)
      summary = attempt.review.presence&.dig("summary")
      return nil if summary.blank?

      findings = Array(attempt.review["findings"]).select { |item| item.is_a?(Hash) }.map(&:deep_stringify_keys)
      { summary:, findings:, accepted: attempt.review_status_accepted?, status: review_status_of(attempt), runtime: attempt.reviewer_runtime }
    end

    REVIEW_STATUSES = %w[accepted changes_requested unavailable].freeze

    # The badge sits on the reviewer's text, so it reads the reviewer's own verdict: the column turns
    # «unavailable» whenever the server refuses the delivery, even after a full review. CYRA-1003
    def review_status_of(attempt)
      [ attempt.review["status"], attempt.review_status ].find { |status| REVIEW_STATUSES.include?(status) }
    end

    FINDING_SEVERITY = { "critical" => "major", "high" => "major", "major" => "major", "medium" => "minor",
                         "minor" => "minor", "low" => "info", "info" => "info" }.freeze
    FINDING_COLOR = { "major" => :red, "minor" => :amber, "info" => :gray }.freeze

    def finding_severity(finding) = FINDING_SEVERITY.fetch(finding["severity"].to_s.downcase, "info")

    # Il resoconto v2 è una dichiarazione dell'agente: la UI lo nomina esplicitamente per non
    # confonderlo con candidate/fingerprint/check osservati dal sistema.
    def automation_work_report(attempt)
      report = attempt&.result&.dig("work_report")
      report.deep_stringify_keys if report.is_a?(Hash)
    end

    # The phase strip of the home reads a decision card; on the ticket there is only the workflow. CYRA-883
    PipelineSource = Data.define(:workflow, :phase, :attempt)

    def automation_pipeline_source(workflow) = PipelineSource.new(workflow:, phase: nil, attempt: nil)

    # CYRA-883 — the amber dot on the Automation tab: the work stands still until a person acts.
    def automation_needs_person?(workflow)
      return false if workflow.nil? || workflow.cancelled_at? || workflow.completed_at?

      # An open automator question waits on a person too.
      ::Agents::Workflows::PhaseResolver::HUMAN_GATED_PHASES.include?(workflow.phase) ||
        workflow.clarifications.where(answered_at: nil).exists?
    end

    def automation_failure(attempt)
      failure = attempt&.result&.dig("failure")
      failure.deep_stringify_keys if failure.is_a?(Hash)
    end
  end
end
