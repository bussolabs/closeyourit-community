# frozen_string_literal: true

require "digest"

module Logs
  module Otlp
    class Record < ApplicationService
      Result = Data.define(:rejected)

      def initialize(project:, payload:)
        @project = project
        @payload = payload
      end

      def call
        decoded = Decode.call(payload: @payload)
        rejected, exceptions, inserted, sources = @project.with_lock { persist(decoded.records) }
        ::Ingest::SourceTracking.track_batch(project: @project, items: sources)
        Logs::Ingest::Notify.call(project: @project, result: inserted) if inserted
        # Error admission owns its own transaction and releases its lock before notification work.
        exceptions.each do |item|
          Exception.call(project: @project, snapshot: item.fetch(:snapshot),
            event_id: item.fetch(:event_id), occurred_at: item.fetch(:occurred_at))
        end
        Result.new(rejected: decoded.rejected + rejected)
      end

      private

      def persist(records)
        identities = records.filter_map { |record| "otlp:#{record[:producer_uid]}" if record[:producer_uid] }
        existing = @project.logs_entries.where(event_id: identities)
          .select(:event_id, :payload_digest, :error_event_id, :occurred_at).index_by(&:event_id)
        rows = []
        sources = []
        exceptions = []
        rejected = 0
        now = Time.current
        records.each do |snapshot|
          identity = snapshot[:producer_uid] ? "otlp:#{snapshot[:producer_uid]}" : SecureRandom.uuid
          digest = Digest::SHA256.hexdigest(JSON.generate(canonical(snapshot)))
          previous = existing[identity]
          if previous
            if previous.payload_digest != digest
              rejected += 1
              next
            end
            error_id = previous.error_event_id
            occurred_at = previous.occurred_at
          else
            row = attributes_for(snapshot, identity, digest, now)
            rows << row
            resource = snapshot.fetch(:resource).fetch("attributes").to_h { |entry| [ entry["key"], entry.fetch("value")["stringValue"] ] }
            sources << Source.new(resource["telemetry.sdk.name"], resource["telemetry.sdk.version"], row[:occurred_at])
            error_id = row[:error_event_id]
            occurred_at = row[:occurred_at]
            existing[identity] = Existing.new(digest, error_id, occurred_at)
          end
          exceptions << { snapshot: snapshot, event_id: error_id, occurred_at: occurred_at } if snapshot[:exception]
        end
        inserted = Logs::Entry::Bulk.insert_all!(rows, returning: %w[id]) if rows.any?
        [ rejected, exceptions.uniq { |item| item.fetch(:event_id) }, inserted, sources ]
      end

      Source = Data.define(:sdk_name, :sdk_version, :occurred_at)
      Existing = Data.define(:payload_digest, :error_event_id, :occurred_at)

      def attributes_for(snapshot, event_id, digest, now)
        log = snapshot.fetch(:record)
        resource = snapshot.fetch(:resource).fetch("attributes").to_h { |entry| [ entry["key"], entry.fetch("value")["stringValue"] ] }
        event_ns = log.fetch("timeUnixNano").to_i
        observed_ns = log.fetch("observedTimeUnixNano").to_i
        occurred_at = event_ns.positive? ? instant(event_ns) : (observed_ns.positive? ? instant(observed_ns) : now)
        message = log.dig("body", "stringValue") || JSON.generate(log.fetch("body"))
        message = log["eventName"].presence || "[OTLP log without body]" if message.blank? || message == "{}"
        message = message.truncate_bytes(Logs::Ingest::Normalize::MESSAGE_MAX_BYTES)
        level = level_for(log.fetch("severityNumber"))
        environment = resource.key?("deployment.environment.name") ? resource["deployment.environment.name"] : resource["deployment.environment"]
        {
          project_id: @project.id, event_id: event_id, level: Logs::Entry.levels.fetch(level), message: message,
          data: { "otlp_attributes" => log.fetch("attributes") }, logger_name: snapshot.fetch(:instrumentation_scope)["name"].presence,
          trace_id: log["traceId"].presence, span_id: log["spanId"].presence, trace_id_extracted: false,
          environment: environment, release: resource["service.version"], occurred_at: occurred_at, created_at: now,
          signal_source: "otlp", severity_number: log.fetch("severityNumber"), severity_text: log.fetch("severityText"),
          event_time_unix_nano: event_ns.to_s, observed_time_unix_nano: observed_ns.to_s,
          otlp_payload: stored_payload(snapshot, resource), payload_digest: digest,
          error_event_id: snapshot[:error_event_id] || (SecureRandom.hex(16) if snapshot[:exception]),
          fingerprint: Logs::Fingerprint.call(message: message, level: level)
        }
      end

      def stored_payload(snapshot, resource)
        conflict = resource.key?("deployment.environment.name") && resource.key?("deployment.environment") &&
          resource["deployment.environment.name"] != resource["deployment.environment"]
        { resource: snapshot[:resource], resource_schema_url: snapshot[:resource_schema_url],
          scope: snapshot[:instrumentation_scope], scope_schema_url: snapshot[:scope_schema_url],
          log_record: snapshot[:record], diagnostics: { environment_conflict: conflict } }
      end

      def instant(nanoseconds)
        Time.at(Rational(nanoseconds, 1_000_000_000)).utc
      end

      def level_for(severity)
        return "info" if severity.zero?
        %w[debug debug info warning error fatal][(severity - 1) / 4]
      end

      def canonical(value)
        case value
        when Hash then value.sort_by { |key, _| key.to_s }.to_h.transform_values { |item| canonical(item) }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end
    end
  end
end
