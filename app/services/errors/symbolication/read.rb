# frozen_string_literal: true

module Errors
  class Symbolication
    class Read < ApplicationService
      def initialize(events:)
        @events = events
      end

      def call
        return {} if @events.empty?
        project_ids = @events.map(&:project_id).uniq
        scope = @events.reduce(Symbolication.none) do |relation, event|
          relation.or(Symbolication.where(project_id: event.project_id, event_id: event.id, event_created_at: event.created_at))
        end
        # One statement measures and conditionally returns JSON under the same MVCC snapshot.
        scoped = scope.select(:project_id, :event_id, :event_created_at, :result).to_sql
        rows = Symbolication.connection.select_all(<<~SQL).to_a
          SELECT project_id, event_id, event_created_at, total_bytes,
                 CASE WHEN total_bytes <= 5242880 THEN result ELSE NULL END AS bounded_result
          FROM (SELECT measured.*, SUM(octet_length(result::text)) OVER () AS total_bytes
                FROM (#{scoped}) measured) bounded
        SQL
        raise ::Artifacts::Rejected, "symbolication_response_budget" if rows.any? { |row| row["total_bytes"].to_i > 5.megabytes }
        records = rows.to_h do |row|
          value = row["bounded_result"]
          value = JSON.parse(value) if value.is_a?(String)
          [ [ row["project_id"], row["event_id"], Symbolication.type_for_attribute("event_created_at").deserialize(row["event_created_at"]) ], value ]
        end
        dependencies = records.transform_values { |result| safe_dependencies(result) }
        available = Dependencies.available(project_ids: project_ids, dependencies: dependencies.values.compact.flatten.uniq)
        native_events = @events.select { |event| event.payload["platform"] == "native" || records.dig([ event.project_id, event.id, event.created_at ], "kind") == "native" }
        native_sources = Native::Source.available(native_events) unless native_events.empty?
        @events.to_h do |event|
          result = result_for_event(event, records, dependencies, available, native_events, native_sources)
          [ [ event.project_id, event.id, event.created_at ], result ]
        end
      end

      private

      def result_for_event(event, records, dependencies, available, native_events, native_sources)
        result = records[[ event.project_id, event.id, event.created_at ]] || { "version" => 1, "status" => "pending", "frames" => [] }
        entries = dependencies.fetch([ event.project_id, event.id, event.created_at ], [])
        missing = entries.nil? || entries.any? { |entry| !available.include?([ event.project_id, entry["kind"], entry["id"] ]) }
        result = { "version" => 1, "kind" => result["kind"], "status" => "unresolved", "reason" => "artifact_deleted", "frames" => [] }.compact if missing
        result = native_result(event, result, native_sources) if native_sources && native_events.include?(event)
        result
      end


      def native_result(event, result, native_sources)
        current = native_sources[[ event.project_id, event.event_id ]]
        expected = result["native"]
        return result if current && (!expected || expected.slice("report_id", "manifest_sha256") == current)
        { "version" => 1, "kind" => "native", "status" => "unresolved", "reason" => "crash_report_unavailable", "frames" => [] }
      end

      def safe_dependencies(result)
        Dependencies.call(result: result)
      rescue ::Artifacts::Rejected
        nil
      end
    end
  end
end
