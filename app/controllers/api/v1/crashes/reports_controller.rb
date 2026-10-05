# frozen_string_literal: true

module Api
  module V1
    module Crashes
      class ReportsController < Api::V1::BaseController
        include OtlpReadBudget
        before_action -> { require_scope!(:read) }
        before_action -> { require_scope!(:ingest) }, only: :destroy

        def index
          scope = visible_reports.order(created_at: :desc, id: :desc)
          scope = scope.where(event_id: params[:event_id].to_s.downcase) if params[:event_id].present?
          rows, meta = paginate_bounded(scope)
          preload_attachments(rows)
          render_bounded(CrashReportSerializer.new(rows), meta: meta)
        end

        def show
          report = bounded_record(visible_reports.where(id: params[:id]))
          preload_attachments([ report ])
          render_bounded(CrashReportSerializer.new(report))
        end

        def destroy
          Current.project.with_lock do
            Current.project.crash_reports.find(params[:id]).destroy!
          end
          ::Crashes::PruneJob.perform_later
          render_no_content
        end

        private

        def visible_reports
          Current.project.crash_reports.linked.where(created_at: ::Crashes::Retention.for(Current.project).days.ago..)
        end

        def preload_attachments(records)
          ActiveRecord::Associations::Preloader.new(records: records, associations: { attachments: :blob }).call
        end
      end
    end
  end
end
