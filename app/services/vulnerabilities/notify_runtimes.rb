# frozen_string_literal: true

module Vulnerabilities
  # Avvisa quando un runtime entra in allarme: fuori supporto, o vicino a esserlo.
  #
  # Nessun ticket automatico qui, a differenza delle vulnerabilità: aggiornare la versione di un
  # linguaggio è un progetto, non una correzione, e aprirlo da soli significherebbe mettere in
  # backlog qualcosa che va deciso e pianificato da una persona.
  class NotifyRuntimes < ApplicationService
    def initialize(statuses:)
      @statuses = Array(statuses)
    end

    def call
      @statuses.each do |status|
        Alerting::EvaluateJob.perform_later(
          event_type: "runtime_eol",
          subject_type: "Vulnerabilities::RuntimeStatus",
          subject_id: status.id,
          project_id: status.project_id,
          environment_id: nil
        )
      end

      Result.ok(@statuses.size)
    end
  end
end
