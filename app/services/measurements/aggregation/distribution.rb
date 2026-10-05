# frozen_string_literal: true

module Measurements
  module Aggregation
    # Histogram algebra keeps distributions; incompatible layouts never become a mean.
    class Distribution
      class Unknown < StandardError; end
      MAX_BUCKETS = 4_096

      def self.combine(left, right, type:, subtract: false)
        new(type: type).combine(left, right, subtract: subtract)
      end

      def initialize(type:)
        @type = type
      end

      def combine(left, right, subtract: false)
        sign = subtract ? -1 : 1
        result = { "count" => nonnegative(left.fetch("count").to_i + sign * right.fetch("count").to_i).to_s }
        if left.key?("sum") && right.key?("sum")
          result["sum"] = decimal(left["sum"]) + sign * decimal(right["sum"])
          raise Unknown, "reset_or_overlap" if result["sum"].negative?
        end
        if @type == "histogram"
          explicit(result, left, right, sign)
        else
          exponential(result, left, right, sign)
        end
        unless subtract
          result["min"] = [ decimal(left["min"]), decimal(right["min"]) ].min if left.key?("min") && right.key?("min")
          result["max"] = [ decimal(left["max"]), decimal(right["max"]) ].max if left.key?("max") && right.key?("max")
        end
        validate_budget(result)
        result
      end

      def self.clean(point, type:)
        fields = %w[count sum min max]
        fields += type == "histogram" ? %w[bucketCounts explicitBounds] : %w[scale zeroCount zeroThreshold positive negative]
        result = point.slice(*fields)
        calculator = new(type: type)
        %w[sum min max].each { |key| result[key] = calculator.send(:decimal, result[key]) if result.key?(key) }
        calculator.send(:validate_budget, result)
        result
      end

      private

      def validate_budget(value)
        count = if @type == "histogram"
          value.fetch("bucketCounts").size
        else
          value.fetch("positive").fetch("bucketCounts").size + value.fetch("negative").fetch("bucketCounts").size
        end
        raise Unknown, "histogram_budget" if count > MAX_BUCKETS
      end

      def explicit(result, left, right, sign)
        raise Unknown, "incompatible_layout" unless left["explicitBounds"] == right["explicitBounds"] && left["bucketCounts"].size == right["bucketCounts"].size
        raise Unknown, "histogram_budget" if left["bucketCounts"].size > MAX_BUCKETS
        result["explicitBounds"] = left.fetch("explicitBounds")
        result["bucketCounts"] = left.fetch("bucketCounts").zip(right.fetch("bucketCounts")).map { |a, b| nonnegative(a.to_i + sign * b.to_i).to_s }
      end

      def exponential(result, left, right, sign)
        raise Unknown, "incompatible_layout" unless left["zeroThreshold"] == right["zeroThreshold"]
        scale = [ left.fetch("scale"), right.fetch("scale") ].min
        result.merge!("scale" => scale, "zeroThreshold" => left.fetch("zeroThreshold"),
          "zeroCount" => nonnegative(left.fetch("zeroCount").to_i + sign * right.fetch("zeroCount").to_i).to_s)
        %w[positive negative].each do |key|
          a = buckets(left.fetch(key), left.fetch("scale") - scale)
          b = buckets(right.fetch(key), right.fetch("scale") - scale)
          keys = a.keys | b.keys
          if keys.empty?
            result[key] = { "offset" => 0, "bucketCounts" => [] }
            next
          end
          first, last = keys.minmax
          raise Unknown, "histogram_budget" if last - first >= MAX_BUCKETS
          counts = (first..last).map { |index| nonnegative(a.fetch(index, 0) + sign * b.fetch(index, 0)).to_s }
          result[key] = { "offset" => first, "bucketCounts" => counts }
        end
      end

      def buckets(value, shift)
        raise Unknown, "histogram_budget" if value.fetch("bucketCounts").size > MAX_BUCKETS
        value.fetch("bucketCounts").each_with_index.with_object(Hash.new(0)) do |(count, index), result|
          index += value.fetch("offset")
          mapped = shift > 64 ? (index.negative? ? -1 : 0) : index >> shift
          result[mapped] += count.to_i
        end
      end

      def nonnegative(value)
        raise Unknown, "reset_or_overlap" if value.negative?
        value
      end

      def decimal(value)
        number = BigDecimal(value.to_s)
        raise Unknown, "nonfinite" unless number.finite?
        number
      end
    end
  end
end
