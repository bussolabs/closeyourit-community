# frozen_string_literal: true

module Traces
  module Browse
    class Related < ApplicationService
      Result = Data.define(:logs, :errors)

      def initialize(project:, trace:, span_id: nil, logs_page: nil, errors_page: nil)
        @project, @trace, @span_id = project, trace, span_id
        @logs_page, @errors_page = logs_page, errors_page
        raise ActiveRecord::RecordNotFound unless trace.project_id == project.id
      end

      def call
        [ Logs::Entry, Errors::Event ].each { |model| model.columns_hash }
        Budget.within do
          logs = @project.logs_entries.where(trace_id: @trace.trace_id)
          direct = @project.error_events.where(trace_id: @trace.trace_id)
          if @span_id
            logs = logs.where(span_id: @span_id)
            direct = direct.where(span_id: @span_id)
          end
          errors = direct.or(@project.error_events.where(event_id: logs.where.not(error_event_id: nil).select(:error_event_id)))
          log_rows = logs.select(:id, :project_id, :event_id, :trace_id, :span_id, :occurred_at, :level, Arel.sql("LEFT(message, 512) AS message"))
          error_rows = errors.select(:id, :project_id, :group_id, :event_id, :trace_id, :span_id, :occurred_at)
          Result.new(logs: page(log_rows, @logs_page), errors: page(error_rows, @errors_page))
        end
      end

      private

      def page(scope, number)
        Pagination.from_query(total: scope.except(:select).count, page: number, per: Pagination::DEFAULT_PER) do |offset, limit|
          Rows.call(scope: scope.order(:occurred_at, :id).offset(offset).limit(limit))
        end
      end
    end
  end
end
