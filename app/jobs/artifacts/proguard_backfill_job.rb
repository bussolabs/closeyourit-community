# frozen_string_literal: true

module Artifacts
  class ProguardBackfillJob < ApplicationJob
    queue_as :batch
    BATCH_SIZE = 100

    def perform(project_id:, proguard_map_id:, after_time: nil, after_id: nil)
      project = Projects::Project.find_by(id: project_id)
      artifact = project&.proguard_map_artifacts&.find_by(id: proguard_map_id)
      return unless artifact
      scope = project.error_events.where(release: artifact.release, created_at: Errors::Retention.for(project).days.ago..)
      scope = scope.where("payload ->> 'platform' = ?", "java")
      # Bind a time value so PostgreSQL compares UTC, not the cursor's local clock.
      scope = scope.where("(created_at, id) > (?, ?)", Time.iso8601(after_time), after_id) if after_time && after_id
      rows = scope.order(:created_at, :id).limit(BATCH_SIZE).pluck(:id, :created_at)
      rows.each { |id, time| Errors::SymbolicateJob.perform_later(project_id: project.id, event_id: id, event_created_at: time.iso8601(6)) }
      if rows.size == BATCH_SIZE
        id, time = rows.last
        self.class.perform_later(project_id: project.id, proguard_map_id: artifact.id, after_time: time.iso8601(6), after_id: id)
      end
    end
  end
end
