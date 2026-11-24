# frozen_string_literal: true

module SessionHealth
  class PruneJob < ApplicationJob
    queue_as :batch
    BATCH_SIZE = 1_000

    def perform
      global_days = Settings::Global.instance.session_health_retention_days
      Projects::Project.includes(:organization).find_each do |project|
        cutoff = Retention.for(project, global_days: global_days).days.ago
        %i[health_sessions health_aggregates].each do |relation|
          loop do
            removed = project.with_lock do
              scope = project.public_send(relation)
              ids = scope.where(created_at: ...cutoff).order(:created_at, :id).limit(BATCH_SIZE).pluck(:id)
              scope.where(id: ids).delete_all
            end
            break if removed.zero?
          end
        end
      end
    end
  end
end
