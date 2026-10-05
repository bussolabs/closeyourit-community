# frozen_string_literal: true

module Api
  module V1
    module Traces
      class SpansController < Api::V1::BaseController
        include OtlpReadBudget

        before_action -> { require_scope!(:read) }

        def index
          trace = Current.project.traces.find_by!(trace_id: params[:trace_id])
          records, meta = paginate_bounded(trace.spans.order(:start_time_unix_nano, :span_id))
          render_bounded(TraceSpanSerializer.new(records), meta: meta)
        end
      end
    end
  end
end
