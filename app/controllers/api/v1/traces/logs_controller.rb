# frozen_string_literal: true

module Api
  module V1
    module Traces
      class LogsController < Api::V1::BaseController
        include OtlpReadBudget
        before_action -> { require_scope!(:read) }

        def index
          trace = Current.project.traces.find_by!(trace_id: params[:trace_id])
          scope = Current.project.logs_entries.where(trace_id: trace.trace_id).order(:occurred_at, :id)
          scope = scope.where(span_id: params[:span_id]) if params[:span_id].present?
          records, meta = paginate_bounded(scope)
          render_bounded(LogEntrySerializer.new(records), meta: meta)
        end
      end
    end
  end
end
