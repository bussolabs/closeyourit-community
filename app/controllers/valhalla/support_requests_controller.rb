# frozen_string_literal: true

module Valhalla
  # Support requests sent from the footer (CYRA-935): the list, one request with its details, and
  # the mark that says someone took care of it.
  class SupportRequestsController < BaseController
    before_action :set_request, only: %i[show update]

    def index
      scope = Support::Request.includes(:account, :organization).order(Arel.sql("handled_at IS NOT NULL"), created_at: :desc)
      scope = scope.where("support_requests.body ILIKE ?", "%#{Support::Request.sanitize_sql_like(search_q)}%") if search_q.present?
      @pagination = paginate(scope)
      @requests = @pagination.records
      @pending_count = Support::Request.pending.count
    end

    def show; end

    def update
      handled = params[:handled] == "1"
      @support_request.update!(handled_at: (Time.current if handled), handled_by: (Current.true_account if handled))
      redirect_to valhalla_support_request_path(@support_request),
                  notice: t(handled ? "valhalla.support_requests.handled" : "valhalla.support_requests.reopened")
    end

    private

    def set_request
      @support_request = Support::Request.find(params[:id])
    end
  end
end
