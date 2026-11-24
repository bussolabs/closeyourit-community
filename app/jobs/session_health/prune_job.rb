# frozen_string_literal: true

module SessionHealth
  class PruneJob < ApplicationJob
    queue_as :batch
    BATCH_SIZE = 1_000

    def perform
      global_days = Settings::Global.instance.session_health_retention_days
      Projects::Project.includes(:organization).find_each do |project|
        cutoff = Retention.for(project, global_days: global_days).days.ago
        loop { break if prune_sessions(project, cutoff).zero? }
        loop do
          scope = project.health_aggregates
          break if scope.where(id: scope.where(created_at: ...cutoff).order(:created_at, :id).limit(BATCH_SIZE).select(:id)).delete_all.zero?
        end
      end
    end

    private

    # Same per-session lock as ingest, whichever takes it first wins: a delivery that got there first
    # keeps the original created_at and is pruned here; a delivery after the delete reads no row and
    # starts a new session. A delivery can never write back a row it read before the delete.
    def prune_sessions(project, cutoff)
      ApplicationRecord.transaction do
        scope = project.health_sessions
        rows = scope.where(created_at: ...cutoff).order(:created_at, :id).limit(BATCH_SIZE).pluck(:id, :sid)
        SessionLock.acquire!(project_id: project.id, sids: rows.map(&:last))
        scope.where(id: rows.map(&:first), created_at: ...cutoff).delete_all
      end
    end
  end
end
