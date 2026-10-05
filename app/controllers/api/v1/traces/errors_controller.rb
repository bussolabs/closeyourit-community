# frozen_string_literal: true

module Api
  module V1
    module Traces
      class ErrorsController < Api::V1::BaseController
        include OtlpReadBudget
        before_action -> { require_scope!(:read) }

        rescue_from ::Artifacts::Rejected do |error|
          render_error("R422-SYMBOLICATION-001", error.message, status: :unprocessable_content)
        end

        def index
          trace = Current.project.traces.find_by!(trace_id: params[:trace_id])
          direct = Current.project.error_events.where(trace_id: trace.trace_id)
          logs = Current.project.logs_entries.where(trace_id: trace.trace_id).where.not(error_event_id: nil)
          if params[:span_id].present?
            direct = direct.where(span_id: params[:span_id])
            logs = logs.where(span_id: params[:span_id])
          end
          scope = direct.or(Current.project.error_events.where(event_id: logs.select(:error_event_id))).order(:occurred_at, :id)
          records, meta = paginate_bounded(scope)
          render_bounded(ErrorEventSerializer.new(records, params: { symbolications: ::Errors::Symbolication::Read.call(events: records) }), meta: meta)
        end
      end
    end
  end
end
