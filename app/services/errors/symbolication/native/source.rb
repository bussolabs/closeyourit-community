# frozen_string_literal: true

module Errors
  class Symbolication
    module Native
      module Source
        module_function

        def scope(project)
          project.crash_reports.linked.where(created_at: ::Crashes::Retention.for(project).days.ago..).where.not(manifest: {})
        end

        def find(event)
          return if event.created_at < Errors::Retention.for(event.project).days.ago
          scope(event.project).find_by(event_id: event.event_id)
        end

        def digest(manifest)
          Digest::SHA256.hexdigest(canonical(manifest).to_json)
        end

        def canonical(value)
          case value
          when Hash then value.keys.sort.to_h { |key| [ key, canonical(value.fetch(key)) ] }
          when Array then value.map { |item| canonical(item) }
          else value
          end
        end

        def validate!(event, result)
          return {} unless result["kind"] == "native" && result.dig("native", "report_id")
          raise ::Artifacts::Unavailable, "Error event expired during resolution" if event.created_at < Errors::Retention.for(event.project).days.ago
          report = scope(event.project).find_by(id: result.dig("native", "report_id"), event_id: event.event_id)
          unless report && digest(report.manifest) == result.dig("native", "manifest_sha256")
            raise ::Artifacts::Unavailable, "Crash report changed during resolution"
          end
          { crash_report_id: report.id, manifest_sha256: digest(report.manifest) }
        end

        def available(events)
          projects = Projects::Project.includes(:organization).where(id: events.map(&:project_id).uniq).index_by(&:id)
          relation = events.group_by(&:project_id).reduce(::Crashes::Report.none) do |scope, (project_id, rows)|
            project = projects[project_id]
            retained = project ? rows.select { |event| event.created_at >= Errors::Retention.for(project).days.ago } : []
            retained.empty? ? scope : scope.or(self.scope(project).where(event_id: retained.map(&:event_id)))
          end
          sql = relation.select(:id, :project_id, :event_id, :manifest).to_sql
          rows = ::Crashes::Report.connection.select_all(<<~SQL)
            SELECT id, project_id, event_id, total_bytes, CASE WHEN total_bytes <= 5242880 THEN manifest ELSE NULL END AS manifest
            FROM (SELECT measured.*, SUM(octet_length(manifest::text)) OVER () AS total_bytes FROM (#{sql}) measured) bounded
          SQL
          raise ::Artifacts::Rejected, "native_source_budget" if rows.any? { |row| row["total_bytes"].to_i > 5.megabytes }
          rows.to_h do |row|
            manifest = row["manifest"]
            manifest = JSON.parse(manifest) if manifest.is_a?(String)
            [ [ row["project_id"], row["event_id"] ], manifest && { "report_id" => row["id"], "manifest_sha256" => digest(manifest) } ]
          end
        end
      end
    end
  end
end
