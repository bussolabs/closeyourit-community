# frozen_string_literal: true

module Api
  module V1
    module SessionHealth
      class SessionsController < Api::V1::BaseController
        include OtlpReadBudget
        before_action -> { require_scope!(:read) }

        def index
          if params[:sid].present? && !params[:sid].to_s.match?(::SessionHealth::Ingest::Decode::UUID)
            return render_error("R422-SESSION-001", "Invalid session identifier", status: :unprocessable_content)
          end
          scope = Current.project.health_sessions.order(started_at: :desc, id: :desc)
          %i[sid release environment status].each { |key| scope = scope.where(key => params[key]) if params[key].present? }
          records, meta = paginate_bounded(scope)
          render_bounded(SessionHealthSerializer.new(records), meta: meta)
        end
      end
    end
  end
end
