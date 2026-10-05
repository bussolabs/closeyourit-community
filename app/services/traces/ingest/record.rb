# frozen_string_literal: true

require "digest"

module Traces
  module Ingest
    class Record < ApplicationService
      Result = Data.define(:rejected)

      def initialize(project:, payload:)
        @project = project
        @payload = payload
      end

      def call
        decoded = Decode.call(payload: @payload)
        return Result.new(rejected: decoded.rejected) if decoded.spans.empty?

        rejected = Traces::Trace.transaction { persist(decoded.spans) }
        Result.new(rejected: decoded.rejected + rejected)
      end

      private

      def persist(snapshots)
        now = Time.current
        groups = snapshots.group_by { |snapshot| snapshot.fetch(:payload).fetch("traceId") }
        traces = lock_traces(groups.keys.sort, now)
        existing = existing_digests(groups)
        rows, conflicts = prepare_rows(snapshots, traces, existing, now)
        Traces::Span.insert_all!(rows) if rows.any?
        rows.group_by { |row| row.fetch(:trace_id) }.each do |trace_id, added|
          trace = traces.fetch(trace_id)
          trace.update!(retained_spans_count: trace.retained_spans_count + added.size,
            last_received_at: [ trace.last_received_at, now ].max)
        end
        conflicts
      end

      def lock_traces(trace_ids, now)
        Traces::Trace.insert_all(trace_ids.map do |trace_id|
          { project_id: @project.id, trace_id: trace_id, first_received_at: now, last_received_at: now }
        end, unique_by: %i[project_id trace_id])
        # Stable ordering prevents deadlocks when two exports share several traces.
        traces = @project.traces.where(trace_id: trace_ids).order(:id).lock.index_by(&:trace_id)
        raise ActiveRecord::RecordNotFound if traces.size != trace_ids.size
        traces.each_value { |trace| trace.project = @project }
        traces
      end

      def existing_digests(groups)
        relation = groups.reduce(@project.trace_spans.none) do |scope, (trace_id, snapshots)|
          ids = snapshots.map { |snapshot| snapshot.fetch(:payload).fetch("spanId") }
          scope.or(@project.trace_spans.where(trace_id: trace_id, span_id: ids))
        end
        relation.pluck(:trace_id, :span_id, :payload_digest).to_h { |trace, span, digest| [ [ trace, span ], digest ] }
      end

      def prepare_rows(snapshots, traces, existing, now)
        rows = []
        conflicts = 0
        snapshots.each do |snapshot|
          payload = snapshot.fetch(:payload)
          identity = [ payload.fetch("traceId"), payload.fetch("spanId") ]
          digest = Digest::SHA256.hexdigest(JSON.generate(canonical(snapshot)))
          if existing.key?(identity)
            conflicts += 1 unless existing.fetch(identity) == digest
          else
            rows << span_attributes(snapshot, traces.fetch(identity.first), now, digest)
            existing[identity] = digest
          end
        end
        [ rows, conflicts ]
      end

      def span_attributes(snapshot, trace, now, digest)
        payload = snapshot.fetch(:payload)
        start_ns = payload.fetch("startTimeUnixNano").to_i
        end_ns = payload.fetch("endTimeUnixNano").to_i
        service = snapshot.fetch(:resource).fetch("attributes").find { |item| item["key"] == "service.name" }&.dig("value", "stringValue")
        snapshot.merge(project_id: @project.id, trace_record_id: trace.id, trace_id: trace.trace_id, span_id: payload.fetch("spanId"),
          parent_span_id: payload["parentSpanId"].presence, name: payload.fetch("name"),
          kind: payload.fetch("kind"), status_code: payload.fetch("status").fetch("code"), service_name: service,
          start_time_unix_nano: start_ns, end_time_unix_nano: end_ns,
          started_at: Time.at(Rational(start_ns, 1_000_000_000)), ended_at: Time.at(Rational(end_ns, 1_000_000_000)),
          first_received_at: now, payload_digest: digest)
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
