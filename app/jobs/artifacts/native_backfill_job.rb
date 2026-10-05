# frozen_string_literal: true

module Artifacts
  class NativeBackfillJob < ApplicationJob
    queue_as :batch
    BATCH_SIZE = 100

    def perform(project_id:, native_symbol_id:, after_time: nil, after_id: nil)
      project = Projects::Project.find_by(id: project_id)
      artifact = project&.native_symbol_artifacts&.find_by(id: native_symbol_id)
      return unless artifact
      uuid = artifact.debug_id.delete("-").first(32)
      scope = Errors::Symbolication::Native::Source.scope(project)
        .where("EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(manifest->'modules', '[]'::jsonb)) module WHERE LEFT(REPLACE(LOWER(module->>'debug_id'), '-', ''), 32) = ?)", uuid)
      # Bind a time value so PostgreSQL compares UTC, not the cursor's local clock.
      scope = scope.where("(created_at, id) > (?, ?)", Time.iso8601(after_time), after_id) if after_time && after_id
      rows = scope.order(:created_at, :id).limit(BATCH_SIZE).pluck(:id, :created_at, :event_id)
      project.error_events.where(event_id: rows.map(&:last), created_at: Errors::Retention.for(project).days.ago..).order(:id).limit(BATCH_SIZE).pluck(:id, :created_at).each do |id, time|
        Errors::SymbolicateJob.perform_later(project_id: project.id, event_id: id, event_created_at: time.iso8601(6))
      end
      if rows.size == BATCH_SIZE
        id, time = rows.last
        self.class.perform_later(project_id: project.id, native_symbol_id: artifact.id, after_time: time.iso8601(6), after_id: id)
      end
    end
  end
end
