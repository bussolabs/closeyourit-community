# frozen_string_literal: true

module Alerting
  module Measurements
    class ScheduleJob < ApplicationJob
      queue_as :alerts
      BATCH_SIZE = 100

      def perform(after_id: nil, window_end: nil)
        ending = window_end || Time.at(((Time.current - Evaluate::GRACE).to_i / 60) * 60).utc.iso8601
        scope = Rule.enabled.where(event_type: :measurement_threshold).order(:id)
        scope = scope.where("id > ?", after_id) if after_id
        rules = scope.limit(BATCH_SIZE).select(:id, :project_id, :measurement_series_id, :measurement_config).to_a
        rules.each { |rule| EvaluateJob.perform_later(rule_id: rule.id, window_end: ending, config_digest: Configuration.digest(rule)) }
        self.class.perform_later(after_id: rules.last.id, window_end: ending) if rules.size == BATCH_SIZE
        return if after_id
        Evaluation.where("dispatch_state = 'pending' OR (dispatch_state = 'delivering' AND dispatch_until < ?)", Time.current)
          .order(:updated_at).limit(BATCH_SIZE).pluck(:id).each { |id| DispatchJob.perform_later(evaluation_id: id) }
        Evaluation.where(status: "unknown", retry_at: ..Time.current).where("window_end_ns >= ?", ((Time.current - Evaluate::RETRY_WINDOW).to_i * 1_000_000_000).to_s)
          .order(:retry_at).limit(BATCH_SIZE).pluck(:rule_id, :window_end_ns, :config_digest).each do |rule_id, ns, digest|
          EvaluateJob.perform_later(rule_id: rule_id, window_end: Time.at(ns.to_i / 1_000_000_000).utc.iso8601, config_digest: digest)
        end
      end
    end
  end
end
