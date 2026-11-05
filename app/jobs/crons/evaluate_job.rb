# frozen_string_literal: true

module Crons
  # Runs every minute (recurring.yml): marks overdue monitors `missed` (no check-in within interval +
  # grace) and alerts once per window (missed_alerted_at, reset by the next check-in).
  class EvaluateJob < ApplicationJob
    queue_as :maintenance

    LAST_RUN_KEY = "crons:evaluate:last_run_at"
    # Three times the schedule step: past this, the check itself was late, not the jobs. CYRA-1141
    LATE_AFTER = 3.minutes

    def perform(now: Time.current)
      return if late_run?(now)

      touched_orgs = {}
      # includes(project: :organization): row and pill broadcasts reach the org via project (anti-N+1).
      Crons::Monitor.enabled.where.not(status: :missed).includes(project: :organization).find_each do |monitor|
        next unless monitor.overdue?(now)

        monitor.update!(status: :missed, missed_alerted_at: now)
        Alerting::EvaluateJob.perform_later(
          event_type: "cron_missed", subject_type: "Crons::Monitor", subject_id: monitor.id,
          project_id: monitor.project_id, environment_id: monitor.environment_id
        )
        # Live update for list/show viewers: row + labels per monitor...
        Crons::Broadcast.row(monitor)
        Crons::Broadcast.labels(monitor)
        touched_orgs[monitor.project.organization_id] = monitor.project.organization
      end
      # ...but the pills once per org (N missed monitors = 1 GROUP BY, not N).
      touched_orgs.each_value { |organization| Crons::Broadcast.stats(organization) }
    end

    private

    # Records this run; after a late run (deploy, clogged queue) skips one round. No record = judge. CYRA-1141
    def late_run?(now)
      last_run_at = Rails.cache.read(LAST_RUN_KEY)
      Rails.cache.write(LAST_RUN_KEY, now, expires_in: 1.day)
      last_run_at.present? && now - last_run_at > LATE_AFTER
    end
  end
end
