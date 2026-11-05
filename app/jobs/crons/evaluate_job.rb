# frozen_string_literal: true

module Crons
  # Gira ogni minuto (recurring.yml): marca `missed` i monitor scaduti (nessun check-in entro
  # intervallo + grazia) e avvisa via Alerting una sola volta per finestra (missed_alerted_at, riazzerato
  # al check-in successivo). Copre i job che smettono silenziosamente di girare.
  class EvaluateJob < ApplicationJob
    queue_as :maintenance

    def perform(now: Time.current)
      touched_orgs = {}
      # includes(project: :organization): riga e pill dei broadcast derivano l'org via project → anti-N+1.
      Crons::Monitor.enabled.where.not(status: :missed).includes(project: :organization).find_each do |monitor|
        next unless monitor.overdue?(now)

        monitor.update!(status: :missed, missed_alerted_at: now)
        Alerting::EvaluateJob.perform_later(
          event_type: "cron_missed", subject_type: "Crons::Monitor", subject_id: monitor.id,
          project_id: monitor.project_id, environment_id: monitor.environment_id
        )
        # Il missed deve arrivare live a chi guarda lista/show: replace riga + labels per monitor...
        Crons::Broadcast.row(monitor)
        Crons::Broadcast.labels(monitor)
        touched_orgs[monitor.project.organization_id] = monitor.project.organization
      end
      # ...ma le pill una sola volta per org (N monitor missed = 1 GROUP BY, non N).
      touched_orgs.each_value { |organization| Crons::Broadcast.stats(organization) }
    end
  end
end
