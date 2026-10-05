# frozen_string_literal: true

module Errors
  module Ingest
    # Validate consumed structures before acknowledging work that cannot be processed.
    module EventPayload
      def self.valid?(payload)
        return false unless payload.is_a?(Hash)
        return false unless optional_types?(payload, %w[contexts request user sdk], Hash)
        return false unless optional_types?(payload, %w[event_id level environment release server_name platform transaction], String)

        exception = payload["exception"]
        return false unless exception.nil? || exception.is_a?(Hash) || exception.is_a?(Array)

        values = exception_values(payload)
        return false unless values.nil? || (values.is_a?(Array) && values.all? { |value| valid_exception?(value) })

        crumbs = payload["breadcrumbs"]
        return false unless crumbs.nil? || crumbs.is_a?(Array) || crumbs.is_a?(Hash)

        true
      end

      # Official SDKs emit both the bare array and the legacy values wrapper.
      def self.exception_values(payload)
        exception = payload["exception"]
        exception.is_a?(Hash) ? exception["values"] : exception
      end

      def self.optional_types?(payload, keys, type)
        keys.all? { |key| payload[key].nil? || payload[key].is_a?(type) }
      end

      def self.valid_exception?(value)
        return false unless value.is_a?(Hash)

        stack = value["stacktrace"]
        return true if stack.nil?
        return false unless stack.is_a?(Hash)

        frames = stack["frames"]
        frames.nil? || (frames.is_a?(Array) && frames.all? { |frame| frame.is_a?(Hash) })
      end
    end
  end
end
