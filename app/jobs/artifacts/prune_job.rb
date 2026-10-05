# frozen_string_literal: true

module Artifacts
  class PruneJob < ApplicationJob
    queue_as :batch
    retry_on ::Artifacts::Unavailable, wait: :polynomially_longer, attempts: 5
    BATCH_SIZE = 100

    def perform(project_id: nil, after_project_id: nil)
      return dispatch(after_project_id) unless project_id
      project = Projects::Project.includes(:organization).find_by(id: project_id)
      more = project ? prune_records(project) : false
      more = prune_blobs(project_id) || more
      self.class.perform_later(project_id: project_id) if more
    end

    private

    def dispatch(after_id)
      scope = Projects::Project.order(:id)
      scope = scope.where("id > ?", after_id) if after_id
      ids = scope.limit(BATCH_SIZE).pluck(:id)
      ids.each { |id| self.class.perform_later(project_id: id) }
      self.class.perform_later(after_project_id: ids.last) if ids.size == BATCH_SIZE
      return if after_id
      Blob.where.not(project_id: Projects::Project.select(:id)).distinct.limit(BATCH_SIZE).pluck(:project_id)
        .each { |id| self.class.perform_later(project_id: id) }
    end

    def prune_records(project)
      project.with_lock do
        cutoff = Errors::Retention.for(project).days.ago
        orphaned = Errors::Symbolication.where(project_id: project.id)
          .where("NOT EXISTS (SELECT 1 FROM errors_events e WHERE e.id = errors_symbolications.event_id AND e.project_id = errors_symbolications.project_id AND e.created_at = errors_symbolications.event_created_at AND e.created_at >= ?)", cutoff)
        expired_native = Errors::Symbolication.where(project_id: project.id).where.not(crash_report_id: nil)
          .where("NOT EXISTS (SELECT 1 FROM crashes_reports c WHERE c.id = errors_symbolications.crash_report_id AND c.project_id = errors_symbolications.project_id AND c.created_at >= ?)", Crashes::Retention.for(project).days.ago)
        orphaned = orphaned.or(expired_native)
        ids = orphaned.order(:id).limit(BATCH_SIZE).pluck(:id)
        orphaned.where(id: ids).delete_all
        source_more = prune_kind(project, "source_map")
        proguard_more = prune_kind(project, "proguard_map")
        native_more = prune_kind(project, "native_symbol")
        ids.size == BATCH_SIZE || source_more || proguard_more || native_more
      end
    rescue ActiveRecord::RecordNotFound
      # A concurrently deleted tenant still has its opaque blobs collected below.
      false
    end

    def prune_kind(project, kind)
      model = Errors::Symbolication::Dependencies.model(kind)
      column = Errors::Symbolication::Dependencies::KINDS.fetch(kind)
      scope = model.where(project_id: project.id)
      references = Artifacts::Reference.arel_table
      referenced = Artifacts::Reference.where(references[column].eq(model.arel_table[:id])).arel.exists
      unused = scope.where(referenced.not)
      newly_unused = unused.where(unreferenced_since: nil).order(:id).limit(BATCH_SIZE).pluck(:id)
      unused.where(id: newly_unused).update_all(unreferenced_since: Time.current)
      expired = unused.where(unreferenced_since: ..Monitoring::Retention.for(project, key: :artifacts).days.ago).order(:id).limit(BATCH_SIZE).pluck(:id)
      scope.where(id: expired).delete_all
      [ newly_unused, expired ].any? { |batch| batch.size == BATCH_SIZE }
    end

    def prune_blobs(project_id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      blobs = Blob.where(project_id: project_id)
        .where("NOT EXISTS (SELECT 1 FROM artifacts_source_maps WHERE blob_id = artifacts_blobs.id)")
        .where("NOT EXISTS (SELECT 1 FROM artifacts_proguard_maps WHERE blob_id = artifacts_blobs.id)")
        .where("NOT EXISTS (SELECT 1 FROM artifacts_native_symbols WHERE blob_id = artifacts_blobs.id)")
        .where("reserved_until <= ? OR NOT EXISTS (SELECT 1 FROM projects WHERE id = artifacts_blobs.project_id)", Time.current)
        .order(:id).limit(BATCH_SIZE).to_a
      blobs.each do |blob|
        return true if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        begin
          blob.with_lock { blob.purge! unless SourceMap.where(blob_id: blob.id).exists? || ProguardMap.where(blob_id: blob.id).exists? || NativeSymbol.where(blob_id: blob.id).exists? }
        rescue ActiveRecord::RecordNotFound
          Rails.logger.debug("Artifact lifecycle row already removed by another collector")
        end
      end
      blobs.size == BATCH_SIZE
    end
  end
end
