# frozen_string_literal: true

module Alerting
  module Measurements
    class Configuration
      class Invalid < StandardError; end
      STATISTICS = { "gauge" => %w[last min max], "sum" => %w[sum rate],
        "histogram" => %w[count sum percentile], "exponentialHistogram" => %w[count sum percentile] }.freeze

      def self.validate!(value, series:)
        raise Invalid, "Invalid measurement configuration" unless value.is_a?(Hash) && value.to_json.bytesize <= 4096
        required = %w[version statistic comparison threshold window_seconds]
        raise Invalid, "Invalid measurement configuration fields" unless (required - value.keys).empty? && (value.keys - required - [ "quantile" ]).empty?
        raise Invalid, "Unsupported measurement configuration" unless value["version"] == 1 && series
        raise Invalid, "Statistic is incompatible with the series" unless STATISTICS.fetch(series.metric_type, []).include?(value["statistic"])
        raise Invalid, "Invalid comparison" unless %w[gt gte lt lte].include?(value["comparison"])
        decimal(value["threshold"])
        raise Invalid, "Window must be between 60 and 86400 seconds" unless value["window_seconds"].is_a?(Integer) && value["window_seconds"].between?(60, 86_400)
        if value["statistic"] == "percentile"
          ::Measurements::Aggregation::Quantile.parse(value["quantile"])
        elsif value.key?("quantile")
          raise Invalid, "Quantile applies only to percentiles"
        end
        value
      rescue ArgumentError
        raise Invalid, "Invalid quantile"
      end

      def self.decimal(value)
        raise Invalid, "Threshold must be a finite decimal string" unless value.is_a?(String) && value.bytesize <= 64 && value.match?(/\A-?\d+(?:\.\d+)?\z/)
        BigDecimal(value)
      end

      def self.digest(rule)
        Digest::SHA256.hexdigest([ rule.project_id, rule.measurement_series_id, rule.measurement_config.sort.to_h ].to_json)
      end
    end
  end
end
