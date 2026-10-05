# frozen_string_literal: true

module Traces
  module Browse
    class Waterfall < ApplicationService
      def initialize(spans:, extent:)
        @spans, @extent = spans, extent
      end

      def call
        index = @spans.index_by(&:span_id)
        @spans.map do |span|
          depth, relation = ancestry(span, index)
          start, ending = @extent.map { |value| value&.to_i }
          duration = span.end_time_unix_nano.to_i - span.start_time_unix_nano.to_i
          total = start && ending ? ending - start : nil
          offset = start ? span.start_time_unix_nano.to_i - start : nil
          { span: span, depth: depth, relation: relation, duration_ns: duration, offset_ns: offset,
            left: percentage(offset, total), width: percentage(duration, total) }
        end
      end

      private

      def percentage(value, total)
        return "0" unless value && total&.positive?
        (BigDecimal(value) * 100 / total).round(6).to_s("F")
      end

      def ancestry(span, index)
        return [ 0, "root" ] unless span.parent_span_id
        return [ 0, span[:observed_parent_present] ? "outside_page" : "missing" ] unless index.key?(span.parent_span_id)
        seen = Set.new([ span.span_id ])
        current, depth = span, 0
        while (parent = index[current.parent_span_id])
          return [ depth, "cycle" ] unless seen.add?(parent.span_id)
          depth += 1
          current = parent
        end
        [ depth, "child" ]
      end
    end
  end
end
