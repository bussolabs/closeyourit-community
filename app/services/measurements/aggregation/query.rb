# frozen_string_literal: true

require "time"
require "date"

module Measurements
  module Aggregation
    class Query < ApplicationService
      class Invalid < StandardError; end
      MAX_POINTS = 10_000
      MAX_PAYLOAD_BYTES = 5 * 1024 * 1024
      MAX_RESPONSE_BYTES = 1024 * 1024
      MAX_BUCKETS = 1_440
      MAX_QUANTILE_ESTIMATES = 1_000
      MAX_QUANTILE_BUCKET_VISITS = 100_000
      Segment = Data.define(:start, :finish, :value, :diagnostics)

      def initialize(series:, from:, to:, interval_seconds: 60, quantiles: [])
        @series = series
        raise Invalid, "Invalid quantiles" unless quantiles.is_a?(Array) && quantiles.size <= 5
        raise Invalid, "Quantiles require a histogram" if quantiles.any? && !%w[histogram exponentialHistogram].include?(@series.metric_type)
        quantiles.each { |value| Quantile.parse(value) }
        @quantiles = quantiles.uniq
        @from = timestamp(from)
        @to = timestamp(to)
        @interval = Integer(interval_seconds.to_s, 10)
        raise Invalid, "Invalid aggregation window" unless @from >= 0 && @to > @from && @to <= (2**64) - 1 && @interval.between?(1, 86_400)
        raise Invalid, "Too many aggregation buckets" if ((@to - @from + @interval * 1_000_000_000 - 1) / (@interval * 1_000_000_000)) > MAX_BUCKETS
        buckets = (@to - @from + @interval * 1_000_000_000 - 1) / (@interval * 1_000_000_000)
        raise Invalid, "Too many percentile estimates" if buckets * @quantiles.size > MAX_QUANTILE_ESTIMATES
        @quantile_visits = 0
      rescue ArgumentError, TypeError
        raise Invalid, "Invalid aggregation window"
      end

      def call
        points, baseline = read_points
        segments = @series.metric_type == "gauge" ? [] : segments(points, baseline)
        buckets = []
        bytes = 0
        start_ns = @from
        while start_ns < @to
          finish = [ start_ns + @interval * 1_000_000_000, @to ].min
          bucket = @series.metric_type == "gauge" ? gauge_bucket(points, start_ns, finish) : aggregate_bucket(segments, start_ns, finish)
          bucket[:quantiles] = estimates(bucket) if @quantiles.any?
          bytes += JSON.generate(bucket).bytesize
          raise Invalid, "Aggregation response exceeds the byte limit" if bytes > MAX_RESPONSE_BYTES
          buckets << bucket
          start_ns = finish
        end
        { api_schema_version: 1, series_id: @series.id, metric_type: @series.metric_type, unit: @series.unit,
          temporality: @series.temporality, monotonic: @series.monotonic,
          from_unix_nano: @from.to_s, to_unix_nano: @to.to_s, interval_seconds: @interval, buckets: buckets }
      end

      private

      def estimates(bucket)
        if bucket[:status] == "known"
          value = bucket.fetch(:value)
          count = value["bucketCounts"]&.size || value.dig("positive", "bucketCounts").size + value.dig("negative", "bucketCounts").size + 1
          @quantile_visits += count * @quantiles.size
          raise Invalid, "Percentile computation exceeds the bucket budget" if @quantile_visits > MAX_QUANTILE_BUCKET_VISITS
        end
        @quantiles.map do |quantile|
          if bucket[:status] == "known"
            Quantile.call(distribution: bucket[:value], type: @series.metric_type, quantile: quantile)
          else
            { quantile: quantile, status: "unknown", method: Quantile::METHOD, estimate: nil,
              lower_bound: nil, upper_bound: nil, diagnostics: bucket[:diagnostics] }
          end
        end
      end

      def timestamp(value)
        pattern = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})\z/
        raise Invalid, "Timestamps require an explicit offset and at most nine fractional digits" unless value.is_a?(String) && value.match?(pattern)
        DateTime.rfc3339(value)
        (Time.iso8601(value.to_s).to_r * 1_000_000_000).to_i
      end

      def read_points
        scope = @series.points.where("time_unix_nano > ? AND time_unix_nano <= ?", @from.to_s, @to.to_s)
        metadata = scope.order(:time_unix_nano, :start_time_unix_nano, :id).limit(MAX_POINTS + 1)
          .pluck(:id, Arel.sql("octet_length(payload::text)"))
        raise Invalid, "Too many points in aggregation window" if metadata.size > MAX_POINTS
        baseline_scope = @series.points.where("time_unix_nano <= ?", @from.to_s).order(time_unix_nano: :desc, start_time_unix_nano: :desc)
        baseline_meta = @series.metric_type == "gauge" ? [] : baseline_scope.limit(2).pluck(:id, Arel.sql("octet_length(payload::text)"))
        raise Invalid, "Aggregation input exceeds the byte limit" if (metadata + baseline_meta).sum(&:last) > MAX_PAYLOAD_BYTES
        rows = @series.points.where(id: metadata.map(&:first)).order(:time_unix_nano, :start_time_unix_nano, :id).map(&:payload)
        previous = @series.points.where(id: baseline_meta.map(&:first)).order(time_unix_nano: :desc, start_time_unix_nano: :desc).map(&:payload)
        @ambiguous_baseline = previous.size > 1 && previous[0]["timeUnixNano"] == previous[1]["timeUnixNano"]
        [ rows, previous.first ]
      end

      def segments(points, previous)
        lost = previous && missing?(previous)
        tainted = nil
        points.map do |point|
          start_ns = point.fetch("startTimeUnixNano").to_i
          end_ns = point.fetch("timeUnixNano").to_i
          diagnostics = []
          value = nil
          if missing?(point)
            diagnostics << "no_recorded_value"
          elsif start_ns.zero? || start_ns == end_ns
            diagnostics << "unknown_start"
          elsif @series.temporality == 1
            value = point_value(point)
          elsif lost || @ambiguous_baseline
            diagnostics << "unknown_baseline"
          elsif tainted == start_ns
            diagnostics << "reset_or_overlap"
          elsif previous && previous["startTimeUnixNano"] == point["startTimeUnixNano"]
            start_ns = previous.fetch("timeUnixNano").to_i
            value = difference(point, previous)
          else
            diagnostics << "reset" if previous
            value = point_value(point)
          end
          segment = Segment.new(start: start_ns, finish: end_ns, value: value, diagnostics: diagnostics)
          previous = point
          lost = missing?(point)
          @ambiguous_baseline = false
          segment
        rescue Distribution::Unknown => error
          tainted = point.fetch("startTimeUnixNano").to_i
          previous = point
          lost = false
          Segment.new(start: start_ns, finish: end_ns, value: nil, diagnostics: [ error.message ])
        end
      end

      def missing?(point)
        (point.fetch("flags", 0) & 1).positive?
      end

      def point_value(point)
        if @series.metric_type == "sum"
          numeric(point)
        else
          Distribution.clean(point, type: @series.metric_type)
        end
      end

      def difference(current, previous)
        if @series.metric_type == "sum"
          difference = numeric(current) - numeric(previous)
          raise Distribution::Unknown, "reset_or_overlap" if @series.monotonic && difference.negative?
          difference
        else
          Distribution.combine(current, previous, type: @series.metric_type, subtract: true)
        end
      end

      def numeric(point)
        value = point.key?("asInt") ? point["asInt"] : point["asDouble"]
        decimal(value)
      end

      def decimal(value)
        number = BigDecimal(value.to_s)
        raise Distribution::Unknown, "nonfinite" unless number.finite?
        number
      rescue ArgumentError
        raise Distribution::Unknown, "missing_value"
      end

      def gauge_bucket(points, start_ns, end_ns)
        selected = points.select { |point| point["timeUnixNano"].to_i > start_ns && point["timeUnixNano"].to_i <= end_ns }
        return bucket(start_ns, end_ns, selected.size, nil, [ "no_data" ]) if selected.empty?
        return bucket(start_ns, end_ns, selected.size, nil, [ "no_recorded_value" ]) if selected.any? { |point| missing?(point) }
        numbers = selected.map { |point| numeric(point) }
        bucket(start_ns, end_ns, selected.size, { last: numbers.last, min: numbers.min, max: numbers.max }, [])
      rescue Distribution::Unknown => error
        bucket(start_ns, end_ns, selected.size, nil, [ error.message ])
      end

      def aggregate_bucket(segments, start_ns, end_ns)
        selected = segments.select { |segment| segment.finish > start_ns && (segment.start < end_ns || (segment.start == segment.finish && segment.finish <= end_ns)) }
        return bucket(start_ns, end_ns, 0, nil, [ "no_data" ]) if selected.empty?
        diagnostics = selected.flat_map(&:diagnostics)
        ordered = selected.sort_by { |segment| [ segment.start, segment.finish ] }
        diagnostics.concat(coverage_diagnostics(ordered, start_ns, end_ns))
        return bucket(start_ns, end_ns, selected.size, nil, diagnostics) if selected.any? { |segment| segment.value.nil? } || (diagnostics - [ "reset" ]).any?
        value = combine(ordered.map(&:value), end_ns - start_ns)
        bucket(start_ns, end_ns, selected.size, value, diagnostics)
      rescue Distribution::Unknown => error
        bucket(start_ns, end_ns, selected.size, nil, diagnostics + [ error.message ])
      end

      def coverage_diagnostics(segments, start_ns, end_ns)
        diagnostics = []
        diagnostics << "bucket_boundary" if segments.any? { |segment| segment.start < start_ns || segment.finish > end_ns }
        cursor = start_ns
        segments.each do |segment|
          diagnostics << "gap" if segment.start > cursor
          diagnostics << "overlap" if segment.start < cursor
          cursor = [ cursor, segment.finish ].max
        end
        diagnostics << "gap" if cursor < end_ns
        diagnostics
      end

      def combine(values, duration)
        if @series.metric_type == "sum"
          sum = values.sum
          { sum: sum, rate: sum / (BigDecimal(duration.to_s) / 1_000_000_000) }
        else
          values.reduce { |left, right| Distribution.combine(left, right, type: @series.metric_type) }
        end
      end

      def bucket(start_ns, end_ns, count, value, diagnostics)
        { start_time_unix_nano: start_ns.to_s, time_unix_nano: end_ns.to_s,
          status: value.nil? ? "unknown" : "known", diagnostics: diagnostics.uniq,
          sample_count: count, value: stringify(value) }
      end

      def stringify(value)
        case value
        when BigDecimal then value.to_s("F").sub(/\.0+\z/, "")
        when Hash then value.transform_values { |item| stringify(item) }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end
    end
  end
end
