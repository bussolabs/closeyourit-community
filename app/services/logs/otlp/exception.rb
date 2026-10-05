# frozen_string_literal: true

module Logs
  module Otlp
    # Only explicitly named exception events enter the error channel; severity is not a crash signal.
    class Exception < ApplicationService
      def initialize(project:, snapshot:, event_id:, occurred_at:)
        @project = project
        @snapshot = snapshot
        @event_id = event_id
        @occurred_at = occurred_at
      end

      def call
        record = @snapshot.fetch(:record)
        attributes = strings(record.fetch("attributes"))
        resource = strings(@snapshot.fetch(:resource).fetch("attributes"))
        value = { "type" => attributes.fetch("exception.type"),
          "value" => attributes["exception.message"] || record.dig("body", "stringValue"),
          "mechanism" => { "type" => "otlp" } }
        payload = { "event_id" => @event_id, "timestamp" => @occurred_at.iso8601(9), "level" => "error",
          "exception" => { "values" => [ value ] },
          "contexts" => { "trace" => { "trace_id" => record["traceId"].presence, "span_id" => record["spanId"].presence } },
          "extra" => { "otel_exception_stacktrace" => attributes["exception.stacktrace"] },
          "release" => resource["service.version"],
          "environment" => resource.key?("deployment.environment.name") ? resource["deployment.environment.name"] : resource["deployment.environment"] }
        if resource["telemetry.sdk.name"].present?
          payload["sdk"] = { "name" => resource["telemetry.sdk.name"], "version" => resource["telemetry.sdk.version"] }
        end
        Errors::Ingest::Record.call(project: @project, payload: payload)
      end

      private

      def strings(attributes)
        attributes.to_h { |entry| [ entry["key"], entry.fetch("value")["stringValue"] ] }
      end
    end
  end
end
