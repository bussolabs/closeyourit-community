# frozen_string_literal: true

module Crons
  # CYRA-477 Scenario 3: quando l'utente ATTIVA la copertura "cron mancato" (crea/abilita la regola dal
  # banner di copertura), i job GIÀ fermi devono ricevere subito l'avviso — altrimenti il guasto in
  # corso resta muto finché il job non recupera e ricade. Crons::EvaluateJob avvisa solo alla
  # TRANSIZIONE verso missed (where.not(status: :missed)), quindi non copre i cron già missed prima che
  # la regola esistesse: ci pensa questo replay una-tantum all'attivazione.
  #
  # Rivaluta i cron enabled e già in stato missed che rientrano nello SCOPE della regola (project/
  # environment nil = tutti). Il de-dup/throttle di Alerting::Evaluate evita le notifiche ripetute (il
  # "rischio" del ticket): un solo avviso per (destinatario, cron, finestra). Il contenuto dell'avviso
  # dice da quanto il job è fermo (Alerting::Content#cron_missed).
  class AlertActiveMissed < ApplicationService
    def initialize(organization:, rule:)
      @organization = organization
      @rule = rule
    end

    def call
      return Result.ok(0) unless @rule.event_cron_missed? && @rule.enabled?

      monitors = covered_missed_monitors.to_a
      monitors.each do |monitor|
        Alerting::EvaluateJob.perform_later(
          event_type: "cron_missed", subject_type: "Crons::Monitor", subject_id: monitor.id,
          project_id: monitor.project_id, environment_id: monitor.environment_id
        )
      end
      Result.ok(monitors.size)
    end

    private

    # Cron dell'org, attivi e attualmente missed, ristretti allo scope della regola: project_id/
    # environment_id valorizzati filtrano (un environment valorizzato esclude i cron senza environment,
    # come environment_match? in Alerting::Evaluate); nil = nessun filtro (org-wide).
    def covered_missed_monitors
      scope = Crons::Monitor.enabled.status_missed
                            .where(project_id: @organization.projects.select(:id))
      scope = scope.where(project_id: @rule.project_id) if @rule.project_id
      scope = scope.where(environment_id: @rule.environment_id) if @rule.environment_id
      scope
    end
  end
end
