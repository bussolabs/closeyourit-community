# frozen_string_literal: true

module Guides
  module Installation
    class Receipt < ApplicationService
      MAX_WINDOW = 24.hours
      DEFAULT_WINDOW = 15.minutes
      QUERY_TIMEOUT_MS = 250
      MAX_RESPONSE_BYTES = 4096

      def initialize(project:, observation:, parameters:, at: Time.current)
        @project, @observation, @parameters, @at = project, observation, parameters.to_h.stringify_keys, at
      end

      def call
        @signal = @observation.dig("tuple", "integration") == "php-laravel-otlp" ? "traces" : "errors"
        raise Invalid, "Observation does not support receipt checking" unless @observation.dig("tuple", "signals").include?(@signal)
        @environment, @release = identity("environment"), identity("release")
        @from, @to = window
        @event_id = identifier("event_id", 32) if @signal == "errors"
        @trace_id, @span_id = identifier("trace_id", 32), identifier("span_id", 16) if @signal == "traces"
        received = bounded_lookup
        data = { state: received ? "received" : "pending", signal: @signal, event_id: @event_id,
          trace_id: @trace_id, span_id: @span_id, received_at: received&.utc&.iso8601(6), environment: @environment, release: @release }
        raise Unavailable, "Receipt response budget exceeded" if JSON.generate(data).bytesize > MAX_RESPONSE_BYTES
        data
      rescue ActiveRecord::QueryCanceled
        raise Unavailable, "Receipt query timed out"
      end

      private

      def identity(key)
        value = @parameters[key]
        raise Invalid, "Invalid receipt identity" unless value.is_a?(String) && value.present? && value.length <= 255 && !value.match?(/[[:cntrl:]]/)
        value
      end

      def identifier(key, size)
        value = @parameters[key]
        raise Invalid, "Invalid receipt identifier" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{#{size}}\z/) && value != "0" * size
        value
      end

      def window
        from, to = @parameters.values_at("from", "to")
        return [ @at - DEFAULT_WINDOW, @at ] if from.nil? && to.nil?
        bounds = [ from, to ].map do |value|
          raise Invalid, "Both UTC receipt bounds are required" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|\+00:00)\z/)
          DateTime.rfc3339(value)
          Time.iso8601(value)
        end
        raise Invalid, "Invalid receipt window" unless bounds.first < bounds.last && bounds.last <= @at && bounds.last - bounds.first <= MAX_WINDOW
        bounds
      rescue ArgumentError
        raise Invalid, "Invalid receipt window"
      end

      def bounded_lookup
        # Cold schema introspection must not consume the telemetry lookup budget.
        (@signal == "errors" ? Errors::Event : Traces::Span).columns_hash
        ApplicationRecord.transaction(requires_new: true) do
          connection = ApplicationRecord.connection
          previous = connection.select_value("SHOW statement_timeout")
          connection.execute("SET LOCAL statement_timeout = '#{QUERY_TIMEOUT_MS}ms'")
          result = @signal == "errors" ? error_receipt : span_receipt
          connection.execute("SET LOCAL statement_timeout = #{connection.quote(previous)}")
          result
        end
      end

      def error_receipt
        @project.error_events.where(event_id: @event_id, environment: @environment, release: @release, created_at: @from..@to)
          .order(:created_at, :id).limit(1).pick(:created_at)
      end

      def span_receipt
        attributes = [ { key: "deployment.environment.name", value: { stringValue: @environment } },
          { key: "service.version", value: { stringValue: @release } } ]
        Traces::Span.where(project_id: @project.id, trace_id: @trace_id, span_id: @span_id, first_received_at: @from..@to)
          .where("resource @> ?::jsonb", JSON.generate(attributes: attributes)).limit(1).pick(:first_received_at)
      end
    end
  end
end
