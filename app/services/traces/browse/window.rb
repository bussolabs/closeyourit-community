# frozen_string_literal: true

module Traces
  module Browse
    class Window < ApplicationService
      def initialize(params:, now: Time.current)
        @params, @now = params.to_h.stringify_keys, now
        @params.slice("from", "to", "range").each_value { |value| raise Invalid, "Invalid trace period" unless value.nil? || value.is_a?(String) }
      end

      def call
        left, right = @params.values_at("from", "to")
        if left.present? || right.present? || @params["range"] == "custom"
          left, right = [ left, right ].map { |value| timestamp(value) }
          raise Invalid, "Invalid trace period" unless left < right && right <= @now && right - left <= 30.days
          return Monitoring::TimeRange.new(key: "custom", from: left, to: right)
        end
        range = @params["range"].presence || "24h"
        duration = Monitoring::TimeRange::PRESETS[range] || raise(Invalid, "Invalid trace period")
        Monitoring::TimeRange.new(key: range, from: @now - duration, to: @now)
      end

      private

      def timestamp(value)
        raise Invalid, "Invalid trace timestamp" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:\d{2})?\z/)
        date = Date._iso8601(value)
        raise ArgumentError unless Date.valid_date?(date[:year], date[:mon], date[:mday]) && date[:hour].between?(0, 23) && date[:min].between?(0, 59) && date.fetch(:sec, 0).between?(0, 59)
        if (offset = value.match(/([+-])(\d{2}):(\d{2})\z/))
          raise ArgumentError unless offset[2].to_i <= 23 && offset[3].to_i <= 59
        end
        Time.zone.parse(value)
      rescue ArgumentError, TypeError
        raise Invalid, "Invalid trace timestamp"
      end
    end
  end
end
