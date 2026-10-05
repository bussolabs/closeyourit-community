# frozen_string_literal: true

module Crashes
  class PruneJob < ApplicationJob
    queue_as :batch
    BATCH_SIZE = 100

    def perform
      global = Settings::Global.instance.crashes_retention_days
      Projects::Project.includes(:organization).find_each do |project|
        cutoff = Retention.for(project, global_days: global).days.ago
        loop do
          count = project.with_lock do
            scope = project.crash_reports.where("created_at < :cutoff OR (created_at < :grace AND NOT EXISTS (SELECT 1 FROM errors_events WHERE project_id = crashes_reports.project_id AND event_id = crashes_reports.event_id) AND NOT EXISTS (SELECT 1 FROM errors_ingest_payloads WHERE project_id = crashes_reports.project_id AND payload->>'event_id' = crashes_reports.event_id))", cutoff: cutoff, grace: 1.hour.ago)
            ids = scope.order(:created_at, :id).limit(BATCH_SIZE).pluck(:id)
            project.crash_reports.where(id: ids).delete_all
          end
          break if count.zero?
        end
      end
      # Cascaded project deletion leaves only opaque lifecycle rows, which are retried here.
      Blob.where("NOT EXISTS (SELECT 1 FROM crashes_attachments WHERE blob_id = crashes_blobs.id)")
          .where("reserved_until <= ? OR NOT EXISTS (SELECT 1 FROM projects WHERE id = crashes_blobs.project_id)", Time.current).find_each do |blob|
        blob.with_lock do
          blob.purge! unless Attachment.where(blob_id: blob.id).exists?
        end
      end
    end
  end
end
