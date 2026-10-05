# frozen_string_literal: true

module Measurements
  module Ingest
    class Decode < ApplicationService
      include ::Ingest::OtlpValues
      TYPES = %w[gauge sum histogram exponentialHistogram summary].freeze
      MAX_POINTS = 1_000
      Result = Data.define(:points, :rejected)

      def initialize(payload:)
        @payload = payload
      end

      def call
        @points = []
        @rejected = 0
        @count = 0
        array(object(@payload)["resourceMetrics"]).each do |resource_group|
          object(resource_group)
          array(resource_group["scopeMetrics"]).each do |scope_group|
            object(scope_group)
            array(scope_group["metrics"]).each { |metric| decode_metric(metric, resource_group, scope_group) }
          end
        end
        Result.new(points: @points, rejected: @rejected)
      end

      private

      def decode_metric(metric, resource_group, scope_group)
        object(metric)
        types = metric.keys & TYPES
        raise Malformed, "Expected one metric type" unless types.one?
        type = types.first
        data = object(metric[type])
        array(data["dataPoints"]).each do |point|
          @count += 1
          raise Malformed, "Too many metric points" if @count > MAX_POINTS
          begin
            raise Rejected, "Unsupported metric type" if type == "summary"
            series = descriptor(metric, type, data, resource_group, scope_group)
            decoded = decode_point(point, type)
            validate_monotonic(decoded, series)
            series[:point_attributes] = decoded.fetch("attributes")
            @points << { series: series, payload: decoded }
          rescue Rejected
            @rejected += 1
          end
        end
      end

      def validate_monotonic(point, series)
        return unless series[:monotonic]
        value = point.key?("asInt") ? point["asInt"].to_i : point["asDouble"]
        raise Rejected, "Monotonic sums cannot be negative" if finite?(value) && value.negative?
      end

      def descriptor(metric, type, data, resource_group, scope_group)
        name = text(metric["name"])
        raise Rejected, "Metric name is required" if name.empty?
        temporality = type == "gauge" ? 0 : integer(data["aggregationTemporality"], min: 1, max: 2)
        { name: name, unit: text(metric["unit"]), description: text(metric["description"]), metric_type: type,
          temporality: temporality, monotonic: type == "sum" ? boolean(data.fetch("isMonotonic", false)) : false,
          resource: resource(resource_group["resource"]), instrumentation_scope: scope(scope_group["scope"]),
          resource_schema_url: text(resource_group["schemaUrl"]), scope_schema_url: text(scope_group["schemaUrl"]) }
      end

      def decode_point(point, type)
        object(point)
        start_ns = integer(point.fetch("startTimeUnixNano", 0))
        end_ns = integer(point["timeUnixNano"], min: [ start_ns, 1 ].max)
        flags = integer(point.fetch("flags", 0), max: (2**32) - 1)
        result = { "startTimeUnixNano" => start_ns.to_s, "timeUnixNano" => end_ns.to_s,
          "attributes" => attributes(point["attributes"]), "flags" => flags }
        missing = (flags & 1).positive?
        return result if missing
        result["exemplars"] = array(point["exemplars"]).map { |exemplar| decode_exemplar(exemplar) }
        value = case type
        when "gauge", "sum" then number(point, optional: missing)
        when "histogram" then explicit_histogram(point, missing: missing)
        when "exponentialHistogram" then exponential_histogram(point, missing: missing)
        end
        result.merge(value)
      end

      def number(value, optional: false)
        keys = value.keys & %w[asInt asDouble]
        return {} if optional && keys.empty?
        raise Rejected, "Expected one numeric value" unless keys.one?
        key = keys.first
        { key => key == "asInt" ? integer(value[key], min: -(2**63), max: (2**63) - 1).to_s : finite_number(value[key]) }
      end

      def decode_exemplar(value)
        object(value)
        result = { "filteredAttributes" => attributes(value["filteredAttributes"]),
          "timeUnixNano" => integer(value.fetch("timeUnixNano", 0)).to_s }.merge(number(value))
        %w[traceId spanId].zip([ 32, 16 ]).each do |key, length|
          result[key] = identifier(value[key], length: length, empty: true) || ""
        end
        result
      end

      def histogram_summary(value)
        result = { "count" => integer(value.fetch("count", 0)).to_s }
        %w[sum min max].each { |key| result[key] = finite_number(value[key]) if value.key?(key) }
        raise Rejected, "Invalid empty histogram sum" if result["count"] == "0" && result.key?("sum") && result["sum"] != 0
        raise Rejected, "Histogram sums cannot be negative" if finite?(result["sum"]) && result["sum"].negative?
        if finite?(result["min"]) && finite?(result["max"]) && result["min"] > result["max"]
          raise Rejected, "Invalid histogram range"
        end
        result
      end

      def explicit_histogram(value, missing:)
        result = histogram_summary(value)
        bounds = array(value["explicitBounds"]).map { |bound| finite_number(bound) }
        counts = array(value["bucketCounts"]).map { |count| integer(count).to_s }
        raise Rejected, "Invalid histogram bounds" unless bounds.all? { |bound| finite?(bound) } && bounds.each_cons(2).all? { |left, right| left < right }
        valid_layout = counts.empty? ? bounds.empty? : counts.size == bounds.size + 1
        raise Rejected, "Invalid histogram buckets" unless valid_layout
        if !missing && counts.any? && counts.sum(&:to_i) != result.fetch("count").to_i
          raise Rejected, "Histogram count mismatch"
        end
        result.merge("explicitBounds" => bounds, "bucketCounts" => counts)
      end

      def exponential_histogram(value, missing:)
        result = histogram_summary(value)
        result["scale"] = integer(value.fetch("scale", 0), min: -(2**31), max: (2**31) - 1)
        result["zeroCount"] = integer(value.fetch("zeroCount", 0)).to_s
        threshold = finite_number(value.fetch("zeroThreshold", 0))
        raise Rejected, "Invalid zero threshold" unless finite?(threshold) && threshold >= 0
        result["zeroThreshold"] = threshold
        %w[positive negative].each do |key|
          buckets = object(value[key] || {})
          result[key] = { "offset" => integer(buckets.fetch("offset", 0), min: -(2**31), max: (2**31) - 1),
            "bucketCounts" => array(buckets["bucketCounts"]).map { |count| integer(count).to_s } }
        end
        total = %w[positive negative].sum { |key| result[key]["bucketCounts"].sum(&:to_i) } + result["zeroCount"].to_i
        raise Rejected, "Histogram count mismatch" unless missing || total == result["count"].to_i
        result
      end

      def finite?(value)
        value.is_a?(Numeric) && value.finite?
      end
    end
  end
end
