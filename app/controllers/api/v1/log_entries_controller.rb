# frozen_string_literal: true

module Api
  module V1
    class LogEntriesController < Api::V1::BaseController
      include OtlpReadBudget
      before_action -> { require_scope!(:read) }

      def index
        scope = ::Logs::Entries::Query.call(
          scope: Current.project.logs_entries, level: params[:level],
          trace_id: params[:trace_id], environment: params[:environment]
        )
        %i[span_id event_id error_event_id].each { |key| scope = scope.where(key => params[key]) if params[key].present? }
        params[:per] = App::Constants::API_PAGE_SIZE if params[:per].blank?
        records, meta = paginate_bounded(scope)
        render_bounded(LogEntrySerializer.new(records), meta: meta)
      end
    end
  end
end
