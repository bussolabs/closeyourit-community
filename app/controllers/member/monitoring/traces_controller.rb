# frozen_string_literal: true

module Member
  module Monitoring
    class TracesController < Member::BaseController
      include Indexable
      permission_not_required "Traces are read-only and restricted to visible projects.", only: %i[index show]
      before_action :validate_parameters
      rescue_from ::Traces::Browse::Invalid, with: :invalid_query
      rescue_from ::Traces::Browse::Unavailable, with: :unavailable_query
      helper_method :trace_window

      def index
        @has_records = visible.traces.exists?
        @saved_views = saved_views_for("traces").limit(100).to_a
        load_projects
        scope = trace_window.apply(visible.traces, column: :last_received_at)
        scope = scope.where(project_id: params[:project_id]) if params[:project_id].present?
        @pagination = ::Traces::Browse::Query.call(scope: scope, params: query_params)
        @traces = @pagination.records
        @row_projects = visible.projects.where(id: @traces.map(&:project_id)).index_by(&:id)
        trace_page
      end

      def show
        @detail = ::Traces::Browse::Detail.call(scope: visible.traces, id: params[:id], page: params[:spans_page], span_id: params[:span_id], per: params[:spans_per] || 50)
        @trace, @selected = @detail.trace, @detail.selected
        @project = visible.projects.find(@trace.project_id)
        @waterfall = ::Traces::Browse::Waterfall.call(spans: @detail.pagination.records, extent: @detail.extent)
        @related = ::Traces::Browse::Related.call(project: @project, trace: @trace, span_id: params[:span_id], logs_page: params[:logs_page], errors_page: params[:errors_page])
        trace_page
      end

      private

      def query_params = params.permit(*::Traces::Browse::Query::FILTERS)
      def trace_window = @trace_window ||= ::Traces::Browse::Window.call(params: params.permit(:range, :from, :to))

      def validate_parameters
        keys = ::Traces::Browse::Query::FILTERS + %w[id project_id project_query range from to span_id spans_page spans_per logs_page errors_page]
        keys.each { |key| raise ::Traces::Browse::Invalid, "Invalid trace parameter" unless params[key].nil? || params[key].is_a?(String) }
        raise ::Traces::Browse::Invalid, "Project search exceeds its limit" if params[:project_query].to_s.bytesize > 128
      end

      def load_projects
        scope = visible.projects
        if params[:project_query].present?
          pattern = "%#{ApplicationRecord.sanitize_sql_like(params[:project_query])}%"
          scope = scope.where("name ILIKE ? OR key ILIKE ?", pattern, pattern)
        end
        selected = visible.projects.where(id: params[:project_id]).limit(1).to_a if params[:project_id].present?
        @projects = (Array(selected) + scope.order(:name, :id).limit(200).to_a).uniq(&:id)
      end

      def trace_page
        content = render_to_string(action_name, layout: "member")
        raise ::Traces::Browse::Invalid, "Rendered trace exceeds the page byte budget" if content.bytesize > 1.megabyte
        render html: content.html_safe, layout: false
      end

      def invalid_query(_error) = render("query_error", status: :unprocessable_content)
      def unavailable_query(_error) = render("query_error", status: :service_unavailable)
    end
  end
end
