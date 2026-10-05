# frozen_string_literal: true

module Logs
  module Ingest
    # Invoke after commit with only the rows inserted by this admission.
    class Notify < ApplicationService
      def initialize(project:, result:)
        @project = project
        @result = result
      end

      def call
        broadcast_refresh(@result)
        notify_alerts(@result)
      end

      private

      def notify_alerts(result)
        inserted_ids = result.rows.flatten
        return if inserted_ids.empty?

        alerting_levels = Logs::Entry.levels.values_at("error", "fatal")
        entries = @project.logs_entries.where(id: inserted_ids, level: alerting_levels).select(:id, :environment, :level).order(:id)
        entries.group_by { |entry| [ entry.environment, entry.level ] }.each_value do |group|
          entry = group.first
          next unless Rails.cache.write("logs:alert:#{@project.id}:#{entry.environment}:#{entry.level}", 1,
                                        unless_exist: true, expires_in: Logs::Constants::ALERT_ENQUEUE_WINDOW)

          Alerting::EvaluateJob.perform_later(
            event_type: "log_alert", subject_type: "Logs::Entry", subject_id: entry.id,
            project_id: @project.id, environment: entry.environment, level: Logs::Entry.levels.fetch(entry.level)
          )
        end
      end

      def broadcast_refresh(result)
        return if result.rows.empty?

        Logs::Broadcast.refresh(@project.organization, projects: [ @project ])
      end
    end
  end
end
