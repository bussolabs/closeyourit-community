# frozen_string_literal: true

module Alerting
  module Measurements
    class Evaluate < ApplicationService
      GRACE = 30.seconds
      RETRY_WINDOW = 5.minutes

      def initialize(rule_id:, window_end:, at: Time.current, config_digest: nil)
        @expected_digest = config_digest
        @rule_id, @ending, @at = rule_id, Time.iso8601(window_end.to_s), at
      rescue ArgumentError
        @rule_id, @ending, @at = rule_id, window_end, at
      end

      def call
        return unless @ending.is_a?(Time) && @ending.nsec.zero? && @ending.to_i % 60 == 0 && @ending <= @at - GRACE
        rule = Rule.includes(:measurement_series, :project).find_by(id: @rule_id, event_type: :measurement_threshold, enabled: true)
        return unless usable?(rule)
        digest = Configuration.digest(rule)
        return if @expected_digest && @expected_digest != digest
        result = observe(rule)
        evaluation = rule.with_lock do
          next unless usable?(rule) && Configuration.digest(rule) == digest
          persist(rule, digest, result)
        end
        DispatchJob.perform_later(evaluation_id: evaluation.id) if evaluation&.dispatch_state == "pending"
        evaluation
      end

      private

      def usable?(rule)
        rule && rule.enabled? && rule.event_measurement_threshold? && rule.measurement_series_id &&
          ::Measurements::Series.exists?(id: rule.measurement_series_id, project_id: rule.project_id)
      end

      def observe(rule)
        config = Configuration.validate!(rule.measurement_config, series: rule.measurement_series)
        window = config.fetch("window_seconds")
        quantiles = config["statistic"] == "percentile" ? [ config.fetch("quantile") ] : []
        bucket = ::Measurements::Aggregation::Query.call(series: rule.measurement_series,
          from: (@ending - window).utc.iso8601(9), to: @ending.utc.iso8601(9), interval_seconds: window, quantiles: quantiles).fetch(:buckets).sole
        result = { "name" => rule.measurement_series.name.truncate(256), "unit" => rule.measurement_series.unit,
          "statistic" => config["statistic"], "comparison" => config["comparison"], "threshold" => config["threshold"],
          "from_unix_nano" => ((@ending.to_i - window) * 1_000_000_000).to_s, "diagnostics" => bucket[:diagnostics], "value" => nil }
        result["unit"] = "#{result['unit']}/s" if config["statistic"] == "rate"
        return result.merge("status" => "unknown") unless bucket[:status] == "known"
        if quantiles.any?
          estimate = bucket.fetch(:quantiles).sole.deep_stringify_keys
          result["quantile"] = estimate
          result["value"] = estimate["estimate"]
          return result.merge("status" => "unknown", "diagnostics" => estimate["diagnostics"]) unless estimate["status"] == "known"
          state = Compare.call(config: config, lower: BigDecimal(estimate["lower_bound"]), upper: BigDecimal(estimate["upper_bound"]),
            lower_inclusive: estimate["lower_inclusive"], upper_inclusive: estimate["upper_inclusive"])
        else
          value = bucket.fetch(:value).with_indifferent_access[config["statistic"]]
          return result.merge("status" => "unknown", "diagnostics" => [ "missing_statistic" ]) if value.nil?
          result["value"] = value.to_s
          state = Compare.call(config: config, lower: BigDecimal(value.to_s), upper: BigDecimal(value.to_s))
        end
        result["diagnostics"] += [ "bucket_uncertainty" ] if state == "unknown"
        result.merge("status" => state)
      rescue ::Measurements::Aggregation::Query::Invalid, Configuration::Invalid => error
        Rails.logger.warn("Measurement evaluation rejected: #{error.class.name}")
        { "status" => "unknown", "value" => nil, "diagnostics" => [ "query_rejected" ] }
      end

      def persist(rule, digest, result)
        key = { rule_id: rule.id, config_digest: digest, series_id: rule.measurement_series_id, window_end_ns: BigDecimal((@ending.to_i * 1_000_000_000).to_s) }
        evaluation = Evaluation.find_or_initialize_by(key)
        evaluation.id ||= SecureRandom.uuid
        return evaluation if evaluation.persisted? && (evaluation.status != "unknown" || @at > @ending + RETRY_WINDOW)
        evaluation.assign_attributes(project_id: rule.project_id, result: result, status: result.fetch("status"),
          retry_at: result["status"] == "unknown" && @at < @ending + RETRY_WINDOW ? @at + 60.seconds : nil)
        current = rule.measurement_state
        newer = current.fetch("window_end_ns", "0").to_i <= key[:window_end_ns]
        if newer && result["status"] != "unknown"
          rule.update_columns(measurement_state: { state: result["status"], config_digest: digest,
            window_end_ns: key[:window_end_ns].to_i.to_s, evaluation_id: evaluation.id })
          evaluation.dispatch_state = "pending" if result["status"] == "firing" && !rule.muted?
        end
        evaluation.save!
        evaluation
      end
    end
  end
end
