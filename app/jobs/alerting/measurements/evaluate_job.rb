# frozen_string_literal: true

module Alerting
  module Measurements
    class EvaluateJob < ApplicationJob
      queue_as :alerts

      def perform(rule_id:, window_end:, config_digest: nil)
        Evaluate.call(rule_id: rule_id, window_end: window_end, config_digest: config_digest)
      end
    end
  end
end
