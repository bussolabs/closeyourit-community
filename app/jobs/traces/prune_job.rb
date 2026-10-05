# frozen_string_literal: true

module Traces
  class PruneJob < ApplicationJob
    queue_as :batch

    def perform
      global_days = Settings::Global.instance.traces_retention_days
      Projects::Project.includes(:organization).find_each do |project|
        cutoff = Retention.for(project, global_days: global_days).days.ago
        project.traces.where(id: project.trace_spans.where(first_received_at: ...cutoff).select(:trace_record_id)).find_each do |trace|
          trace.with_lock do
            removed = trace.spans.where(first_received_at: ...cutoff).delete_all
            remaining = trace.spans.count
            if remaining.zero?
              trace.destroy!
            else
              trace.update!(retained_spans_count: remaining, expired_spans_count: trace.expired_spans_count + removed)
            end
          end
        rescue ActiveRecord::RecordNotFound
          # Another pruning pass already removed this empty trace.
          next
        end
      end
    end
  end
end
