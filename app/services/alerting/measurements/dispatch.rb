# frozen_string_literal: true

module Alerting
  module Measurements
    class Dispatch < ApplicationService
      def initialize(evaluation_id:)
        @id = evaluation_id
      end

      def call
        evaluation = Evaluation.find_by(id: @id)
        return unless evaluation
        claimed = evaluation.with_lock do
          next false unless evaluation.dispatch_state == "pending" || (evaluation.dispatch_state == "delivering" && evaluation.dispatch_until < Time.current)
          unless self.class.current?(evaluation, evaluation.rule.reload)
            evaluation.update!(dispatch_state: "cancelled")
            next false
          end
          evaluation.update!(dispatch_state: "delivering", dispatch_until: 1.minute.from_now)
          true
        end
        return unless claimed
        Alerting::Evaluate.call(event_type: "measurement_threshold", subject_type: "Alerting::Evaluation",
          subject_id: evaluation.id, project_id: evaluation.project_id, rule_id: evaluation.rule_id,
          at: Time.at(evaluation.window_end_ns.to_i / 1_000_000_000).utc)
        evaluation.update!(dispatch_state: "delivered", dispatch_until: nil)
      rescue StandardError
        evaluation&.update_columns(dispatch_state: "pending", dispatch_until: nil) if claimed && evaluation&.persisted?
        raise
      end

      def self.current?(evaluation, rule)
        rule.event_measurement_threshold? && rule.enabled? && !rule.muted? && rule.project_id == evaluation.project_id &&
          rule.measurement_series_id == evaluation.series_id && Configuration.digest(rule) == evaluation.config_digest &&
          rule.measurement_state["state"] == "firing" && rule.measurement_state["window_end_ns"].to_i == evaluation.window_end_ns.to_i
      end
    end
  end
end
