# frozen_string_literal: true

module Measurements
  class PruneJob < ApplicationJob
    queue_as :batch
    BATCH_SIZE = 1_000

    def perform
      global_days = Settings::Global.instance.measurements_retention_days
      Projects::Project.includes(:organization).find_each do |project|
        cutoff = Retention.for(project, global_days: global_days).days.ago
        loop do
          removed = project.with_lock { prune_batch(project, cutoff) }
          break if removed.zero?
        end
      end
    end

    private

    def prune_batch(project, cutoff)
      batch = project.measurement_points.where(first_received_at: ...cutoff).order(:first_received_at, :id).limit(BATCH_SIZE).pluck(:id, :series_id)
      return 0 if batch.empty?
      project.measurement_points.where(id: batch.map(&:first)).delete_all
      candidates = project.measurement_series.where(id: batch.map(&:last).uniq)
      candidates.where.not(id: project.measurement_points.where(series_id: candidates.select(:id)).select(:series_id)).delete_all
      batch.size
    end
  end
end
