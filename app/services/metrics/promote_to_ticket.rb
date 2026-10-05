# frozen_string_literal: true

module Metrics
  # Promuove un gruppo-metrica (query/metodo lento) a ticket: mappa la signature lenta su UNO scenario
  # BDD e sposta i dettagli tecnici (env/database) in technical_analysis. Specializza
  # Observability::PromoteToTicket. reporter = chi promuove (UI Member). Mirror di Errors::PromoteToTicket.
  class PromoteToTicket < Observability::PromoteToTicket
    private

    def already_promoted_code = "R422-METRIC-001"

    def ticket_params
      sample = @group.samples.order(occurred_at: :desc).first
      {
        project_id: @group.project_id,
        title: @group.title.to_s.truncate(255),
        technical_analysis: technical_details(sample),
        scenarios_attributes: [ {
          step_given: "Reported from performance monitoring.",
          step_when: @group.title.presence || "Unknown query/method",
          step_then: observed_clause,
          step_expected: "Should complete within budget."
        } ],
        status_id: default_status&.id,
        priority_id: default_priority&.id
      }
    end

    def observed_clause
      "Average #{@group.average_duration_ms.round}ms over #{@group.samples_count} occurrences."
    end

    # Dettagli tecnici della metrica → technical_analysis (registro tecnico, fuori dal corpo human-simple).
    def technical_details(sample)
      return nil if sample.nil?

      parts = []
      parts << "Environment: #{sample.environment}" if sample.environment.present?
      db_system = sample.payload["db_system"]
      parts << "Database: #{db_system}" if db_system.present?
      # Valori d'ingest senza tetto (li manda il client): troncati al limite del campo, così la
      # promozione non fallisce per un environment o un db_system abnorme.
      parts.presence&.join("\n")&.truncate(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
    end
  end
end
