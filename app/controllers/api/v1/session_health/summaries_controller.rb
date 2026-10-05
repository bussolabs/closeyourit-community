# frozen_string_literal: true

module Api
  module V1
    module SessionHealth
      class SummariesController < Api::V1::BaseController
        include OtlpReadBudget
        before_action -> { require_scope!(:read) }

        def index
          result = ::SessionHealth::Query.new(sessions: Current.project.health_sessions, aggregates: Current.project.health_aggregates,
            release: params[:release], environment: params[:environment], from: params[:from], to: params[:to], source: params[:source])
            .call(page: params[:page], per: params[:per].presence || Pagination::MACHINE_DEFAULT_PER)
          meta = { page: result.page, per: result.per, total: result.total, total_pages: result.total_pages }
          render_bounded(result.records, meta: meta)
        rescue ::SessionHealth::Query::Invalid => error
          render_error("R422-SESSION-001", error.message, status: :unprocessable_content)
        end
      end
    end
  end
end
