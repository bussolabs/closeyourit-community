# frozen_string_literal: true

module Uptime
  # Retention per granularità sulla stessa tabella. Raw (3g) e hourly (90g) restano costanti fisse
  # (buffer interni dei rollup); il daily è potato PER-PROGETTO (god → org → progetto, come i log —
  # CYRA-159) perché è la storia a lungo termine visibile all'utente. Gli incident (uptime_incidents)
  # NON sono toccati — restano la fonte di verità delle finestre outage.
  class PruneJob < ApplicationJob
    queue_as :batch

    def perform
      Uptime::Check.granularity_check
                   .where(checked_at: ..Uptime::Constants::RAW_RETENTION_DAYS.days.ago)
                   .in_batches.delete_all
      Uptime::Check.granularity_hourly
                   .where(checked_at: ..Uptime::Constants::HOURLY_RETENTION_DAYS.days.ago)
                   .in_batches.delete_all

      # Singleton god risolto UNA volta (non per-progetto) + organization in eager load → niente N+1.
      global_days = Uptime::Retention.resolve(Settings::Global.instance.uptime_retention_days)

      Projects::Project.includes(:organization).find_each do |project|
        days = Uptime::Retention.for(project, global_days: global_days)
        Uptime::Check.granularity_daily
                     .where(monitor_id: project.uptime_monitors.select(:id))
                     .where(checked_at: ..days.days.ago)
                     .in_batches.delete_all
      end
    end
  end
end
