# frozen_string_literal: true

module Errors
  class Symbolication
    module Native
      class ReportRead < ApplicationService
        MAX_BYTES = 5.megabytes

        def initialize(project:, events:)
          @project, @events = project, events
        end

        def call
          retained = @events.select { |event| event.project_id == @project.id && event.created_at >= Errors::Retention.for(@project).days.ago }
          return {} if retained.empty?
          scope = Source.scope(@project).where(event_id: retained.map(&:event_id)).select(:id, :event_id, :manifest)
          rows = ::Crashes::Report.connection.select_all(<<~SQL)
            SELECT id, event_id, total_bytes,
                   CASE WHEN total_bytes <= #{MAX_BYTES} THEN manifest ELSE NULL END AS bounded_native_manifest
            FROM (SELECT reports.*, SUM(octet_length(manifest::text)) OVER () AS total_bytes FROM (#{scope.to_sql}) reports) bounded
          SQL
          raise ::Artifacts::Rejected, "native_source_budget" if rows.any? { |row| row["total_bytes"].to_i > MAX_BYTES }
          rows.to_h do |row|
            manifest = row["bounded_native_manifest"]
            manifest = JSON.parse(manifest) if manifest.is_a?(String)
            [ row["event_id"], { "id" => row["id"], "manifest" => manifest, "manifest_sha256" => Source.digest(manifest) } ]
          end
        end
      end
    end
  end
end
