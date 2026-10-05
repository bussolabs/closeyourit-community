# frozen_string_literal: true

module Metrics
  module Ingest
    # Only the pinned, closed contract can opt a sample into versioned grouping.
    class JobContext
      ROOT = Rails.root.join("contracts/jobs/v1")
      SCHEMA = JSON.parse(ROOT.join("schema.json").read)
      VALIDATOR = JSONSchemer.schema({ "$ref" => "#/$defs/job_context", "$defs" => SCHEMA.fetch("$defs") },
        regexp_resolver: "ecma", format: true, ref_resolver: ->(_) { raise ArgumentError, "External job references are disabled" })
      NUMBER_FIELDS = %w[duration_ms queue_wait_ms scheduled_delay_ms].freeze
      TIME_FIELDS = %w[enqueued_at scheduled_at started_at].freeze
      TOLERANCE_MS = 0.011

      def self.valid?(context)
        return false unless bounded?(context) && VALIDATOR.valid?(context)
        return false unless NUMBER_FIELDS.all? { |key| context[key].nil? || context[key].to_f.finite? }

        times = TIME_FIELDS.to_h { |key| [ key, context[key] && Time.iso8601(context[key]) ] }
        timing_valid?(context, times)
      rescue ArgumentError, RangeError
        false
      end

      def self.bounded?(context)
        context.is_a?(Hash) && context.size <= 18 && context.all? do |key, value|
          key.is_a?(String) && key.bytesize <= 32 &&
            (value.nil? || value == true || value == false || value.is_a?(Numeric) || (value.is_a?(String) && value.bytesize <= 1024))
        end
      end
      private_class_method :bounded?

      def self.timing_valid?(context, times)
        enqueue, schedule, start = times.values_at(*TIME_FIELDS)
        wait, delay = context.values_at("queue_wait_ms", "scheduled_delay_ms")
        return false unless wait.nil? || wait_valid?(context, enqueue, schedule, start, wait)
        return true if delay.nil?
        return false unless enqueue && schedule

        (delay - [ (schedule - enqueue) * 1000, 0 ].max).abs <= TOLERANCE_MS
      end
      private_class_method :timing_valid?

      def self.wait_valid?(context, enqueue, schedule, start, wait)
        return false unless enqueue && start

        due = schedule ? [ enqueue, schedule ].max : enqueue
        elapsed = (start - due) * 1000
        (wait - [ elapsed, 0 ].max).abs <= TOLERANCE_MS && (elapsed >= 0 || context["clock_skew"] == true)
      end
      private_class_method :wait_valid?
    end
  end
end
