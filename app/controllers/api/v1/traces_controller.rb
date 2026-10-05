# frozen_string_literal: true

module Api
  module V1
    class TracesController < Api::V1::BaseController
      before_action -> { require_scope!(:read) }
      rescue_from ::Traces::Browse::Invalid do
        render_error("R422-TRACE-001", "Invalid trace filters", status: :unprocessable_content)
      end
      rescue_from ::Traces::Browse::Unavailable do
        render_error("R503-TRACE-001", "Trace lookup is temporarily unavailable", status: :service_unavailable)
      end

      def index
        return filtered_index if (::Traces::Browse::Query::FILTERS - %w[page per]).any? { |key| params.key?(key) }

        records, meta = paginate(Current.project.traces.order(last_received_at: :desc, id: :desc))
        observed = Current.project.traces.with_topology.where(id: records.map(&:id)).index_by(&:id)
        render_ok(TraceSerializer.new(records.filter_map { |record| observed[record.id] }), meta: meta)
      end

      def show
        render_ok(TraceSerializer.new(Current.project.traces.find_by!(trace_id: params[:id])))
      end
      private

      def filtered_index
        keys = ::Traces::Browse::Query::FILTERS
        raise ::Traces::Browse::Invalid unless keys.all? { |key| params[key].nil? || params[key].is_a?(String) }
        filters = params.permit(*keys).to_h
        filters["per"] = Pagination::MACHINE_DEFAULT_PER.to_s if filters["per"].blank?
        result = ::Traces::Browse::Query.call(scope: Current.project.traces, params: filters)
        meta = { page: result.page, per: result.per, total: result.total, total_pages: result.total_pages }
        render_ok(TraceSerializer.new(result.records), meta: meta)
      end
    end
  end
end
