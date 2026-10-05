# frozen_string_literal: true

module Alerting
  module Measurements
    class Compare < ApplicationService
      def initialize(config:, lower:, upper:, lower_inclusive: true, upper_inclusive: true)
        @config, @lower, @upper, @lower_inclusive, @upper_inclusive = config, lower, upper, lower_inclusive, upper_inclusive
      end

      def call
        threshold = Configuration.decimal(@config.fetch("threshold"))
        firing, safe = case @config.fetch("comparison")
        when "gt" then [ @lower > threshold || (@lower == threshold && !@lower_inclusive), @upper <= threshold ]
        when "gte" then [ @lower >= threshold, @upper < threshold || (@upper == threshold && !@upper_inclusive) ]
        when "lt" then [ @upper < threshold || (@upper == threshold && !@upper_inclusive), @lower >= threshold ]
        when "lte" then [ @upper <= threshold, @lower > threshold || (@lower == threshold && !@lower_inclusive) ]
        end
        firing ? "firing" : (safe ? "safe" : "unknown")
      end
    end
  end
end
