# frozen_string_literal: true

module Traces
  module Browse
    class Detail < ApplicationService
      Result = Data.define(:trace, :pagination, :selected, :extent)

      def initialize(scope:, id:, page: nil, span_id: nil, per: 50)
        @scope, @id, @page, @span_id = scope, id, page, span_id
        @per = per.to_i.clamp(1, 50)
        raise Invalid, "Invalid trace identifier" unless id.is_a?(String) && id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
        raise Invalid, "Invalid span identifier" unless span_id.nil? || span_id.is_a?(String) && span_id.match?(/\A[0-9a-f]{16}\z/) && span_id != "0" * 16
      end

      def call
        Budget.within do
          trace = @scope.with_topology.find(@id)
          scope = trace.spans.select("traces_spans.*", <<~SQL.squish)
            EXISTS (SELECT 1 FROM traces_spans parents WHERE parents.trace_record_id = traces_spans.trace_record_id
              AND parents.span_id = traces_spans.parent_span_id) AS observed_parent_present
          SQL
          extent = trace.spans.pick(Arel.sql("MIN(start_time_unix_nano)"), Arel.sql("MAX(end_time_unix_nano)"))
          pagination = Pagination.from_query(total: trace.spans.count, page: @page, per: @per) do |offset, limit|
            Rows.call(scope: scope.order(:start_time_unix_nano, :span_id).offset(offset).limit([ limit, 50 ].min))
          end
          selected = @span_id ? Rows.call(scope: scope.where(span_id: @span_id).limit(1)).first : pagination.records.first
          raise ActiveRecord::RecordNotFound if @span_id && !selected
          Result.new(trace: trace, pagination: pagination, selected: selected, extent: extent)
        end
      end
    end
  end
end
