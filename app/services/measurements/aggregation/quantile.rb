# frozen_string_literal: true

require "bigdecimal/math"

module Measurements
  module Aggregation
    # Linear interpolation is a product estimate; bounds describe bucket uncertainty.
    class Quantile < ApplicationService
      METHOD = "linear_bucket_v1"
      Bucket = Data.define(:lower, :upper, :count, :lower_inclusive, :upper_inclusive)

      def self.parse(value)
        raise ArgumentError, "Invalid quantile" unless value.is_a?(String) && value.bytesize <= 64 && value.match?(/\A(?:0(?:\.\d+)?|1(?:\.0+)?)\z/)
        BigDecimal(value)
      end

      def initialize(distribution:, type:, quantile:)
        @value, @type, @quantile = distribution, type, quantile
        @q = self.class.parse(quantile)
      end

      def call
        count = integer(@value.fetch("count"))
        raise Distribution::Unknown, "empty_distribution" if count.zero?
        buckets = @type == "histogram" ? explicit : exponential
        raise Distribution::Unknown, "invalid_distribution" unless buckets.sum(&:count) == count
        rank = @q * count
        before = 0
        selected = buckets.find do |bucket|
          hit = bucket.count.positive? && before + bucket.count >= rank
          before += bucket.count unless hit
          hit
        end
        raise Distribution::Unknown, "invalid_distribution" unless selected
        raise Distribution::Unknown, "unbounded_bucket" unless selected.lower && selected.upper
        lower, upper = selected_bounds(selected)
        fraction = ((rank - before) / selected.count).clamp(0, 1)
        value = lower + fraction * (upper - lower)
        { quantile: @quantile, status: "known", method: METHOD, estimate: text(value),
          lower_bound: text(lower), upper_bound: text(upper),
          lower_inclusive: selected.lower_inclusive, upper_inclusive: selected.upper_inclusive,
          diagnostics: [] }
      rescue Distribution::Unknown, KeyError, ArgumentError, TypeError => error
        diagnostic = error.is_a?(Distribution::Unknown) ? error.message : "invalid_distribution"
        { quantile: @quantile, status: "unknown", method: METHOD, estimate: nil,
          lower_bound: nil, upper_bound: nil, diagnostics: [ diagnostic ] }
      end

      private

      def selected_bounds(bucket)
        lower = bucket.lower.respond_to?(:call) ? bucket.lower.call : bucket.lower
        upper = bucket.upper.respond_to?(:call) ? bucket.upper.call : bucket.upper
        raise Distribution::Unknown, "unrepresentable_bounds" if upper < lower || (upper == lower && !(bucket.lower_inclusive && bucket.upper_inclusive))
        [ lower, upper ]
      end

      def explicit
        bounds = @value.fetch("explicitBounds").map { |value| decimal(value) }
        counts = @value.fetch("bucketCounts")
        raise Distribution::Unknown, "invalid_distribution" unless counts.size == bounds.size + 1 && bounds.each_cons(2).all? { |a, b| b > a }
        raise Distribution::Unknown, "histogram_budget" if counts.size > Distribution::MAX_BUCKETS
        counts.each_with_index.map do |count, index|
          Bucket.new(lower: index.zero? ? nil : bounds[index - 1], upper: bounds[index], count: integer(count), lower_inclusive: false, upper_inclusive: true)
        end
      end

      def exponential
        scale = @value.fetch("scale")
        raise Distribution::Unknown, "unrepresentable_bounds" unless scale.is_a?(Integer) && scale.between?(-20, 20)
        threshold = decimal(@value.fetch("zeroThreshold"))
        raise Distribution::Unknown, "invalid_distribution" if threshold.negative?
        positive = side(@value.fetch("positive"), scale, threshold, negative: false)
        negative = side(@value.fetch("negative"), scale, threshold, negative: true).reverse
        raise Distribution::Unknown, "histogram_budget" if positive.size + negative.size > Distribution::MAX_BUCKETS
        zero = Bucket.new(lower: -threshold, upper: threshold, count: integer(@value.fetch("zeroCount")), lower_inclusive: true, upper_inclusive: true)
        negative + [ zero ] + positive
      end

      def side(value, scale, threshold, negative:)
        counts = value.fetch("bucketCounts")
        raise Distribution::Unknown, "histogram_budget" if counts.size > Distribution::MAX_BUCKETS
        occupied = counts.each_index.select { |index| integer(counts[index]).positive? }
        validate_side(value.fetch("offset"), occupied, scale, threshold) if occupied.any?
        counts.each_with_index.filter_map do |count, index|
          count = integer(count)
          next if count.zero?
          index += value.fetch("offset")
          lower = -> { [ power(index, scale, outward: -1), threshold ].max }
          upper = -> { power(index + 1, scale, outward: 1) }
          Bucket.new(lower: negative ? -> { -upper.call } : lower, upper: negative ? -> { -lower.call } : upper,
            count: count, lower_inclusive: negative, upper_inclusive: !negative)
        end
      end

      def validate_side(offset, occupied, scale, threshold)
        first, last = occupied.minmax.map { |index| index + offset }
        factor = BigDecimal("2")**(-scale)
        unless (BigDecimal(first.to_s) * factor).between?(-1022, 1023) && (BigDecimal((last + 1).to_s) * factor).between?(-1022, 1023)
          raise Distribution::Unknown, "unrepresentable_bounds"
        end
        raise Distribution::Unknown, "invalid_distribution" if threshold >= power(first + 1, scale, outward: -1)
      end

      def power(index, scale, outward:)
        exponent = BigDecimal(index.to_s) * (BigDecimal("2")**(-scale))
        raise Distribution::Unknown, "unrepresentable_bounds" unless exponent.between?(-1022, 1023)
        return BigDecimal("2")**exponent.to_i if exponent.frac.zero?
        value = BigMath.exp(exponent * BigMath.log(BigDecimal("2"), 60), 60)
        # Widen the high-precision computed boundary before conservative comparisons.
        value + outward * value.abs * BigDecimal("1e-45")
      end

      def integer(value)
        raise Distribution::Unknown, "invalid_distribution" unless value.to_s.match?(/\A\d{1,24}\z/) && value.to_i <= ((2**64) - 1) * 10_000
        value.to_i
      end

      def decimal(value)
        number = BigDecimal(value.to_s)
        raise Distribution::Unknown, "nonfinite" unless number.finite?
        number
      end

      def text(value) = value.zero? ? "0" : value.to_s("F").sub(/\.0+\z/, "")
    end
  end
end
