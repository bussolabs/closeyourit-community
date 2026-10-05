# frozen_string_literal: true

module Errors
  class Symbolication
    class Record < ApplicationService
      def initialize(event:)
        @event = event
      end

      def call
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = Resolve.call(event: @event)
        stored = if result["kind"] == "native"
          remaining = 30 - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
          raise ::Artifacts::Unavailable, "Native resolution deadline exceeded" unless remaining.positive?
          Timeout.timeout(remaining, ::Artifacts::Unavailable, "Native resolution deadline exceeded") { persist(result) }
        else
          persist(result)
        end
        raise ::Artifacts::Unavailable, "Symbolication processing is unavailable" if result["retryable"]
        stored
      end

      private

      def persist(result)
        project = @event.project
        project.with_lock do
          return unless project.error_events.where(id: @event.id, created_at: @event.created_at).exists?
          dependencies = Dependencies.call(result: result)
          available = Dependencies.available(project_ids: [ project.id ], dependencies: dependencies)
          unless dependencies.all? { |entry| available.include?([ project.id, entry["kind"], entry["id"] ]) }
            raise ::Artifacts::Unavailable, "Artifact changed during resolution"
          end
          record = Symbolication.find_or_initialize_by(project_id: project.id, event_id: @event.id, event_created_at: @event.created_at)
          source = Native::Source.validate!(@event, result)
          record.update!(result: result, crash_report_id: source[:crash_report_id], manifest_sha256: source[:manifest_sha256])
          record.artifact_references.delete_all
          unless dependencies.empty?
            ::Artifacts::Reference.insert_all!(dependencies.map { |entry| { project_id: project.id, source_map_id: nil, proguard_map_id: nil, native_symbol_id: nil, Dependencies::KINDS.fetch(entry["kind"]).to_sym => entry["id"], symbolication_id: record.id, created_at: Time.current, updated_at: Time.current } })
            dependencies.group_by { |entry| entry["kind"] }.each do |kind, entries|
              Dependencies.model(kind).where(project_id: project.id, id: entries.map { |entry| entry["id"] }).update_all(unreferenced_since: nil)
            end
          end
          record.artifact_references.reset
          record
        end
      end
    end
  end
end
