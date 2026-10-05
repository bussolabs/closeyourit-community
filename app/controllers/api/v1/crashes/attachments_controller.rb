# frozen_string_literal: true

module Api
  module V1
    module Crashes
      class AttachmentsController < Api::V1::BaseController
        before_action -> { require_scope!(:read) }
        before_action -> { require_scope!(:ingest) }, only: :destroy

        def download
          attachment = scoped.find(params[:id])
          response.headers["X-Content-Type-Options"] = "nosniff"
          response.headers["Cache-Control"] = "private, no-store"
          send_data attachment.blob.service.download(attachment.blob.key), filename: attachment.filename,
                    type: "application/octet-stream", disposition: "attachment"
        end

        def destroy
          Current.project.with_lock { scoped.find(params[:id]).destroy! }
          ::Crashes::PruneJob.perform_later
          render_no_content
        end

        private

        def scoped
          ::Crashes::Attachment.where(project_id: Current.project.id, report_id: Current.project.crash_reports.linked.where(created_at: ::Crashes::Retention.for(Current.project).days.ago..).select(:id)).includes(:blob)
        end
      end
    end
  end
end
