# frozen_string_literal: true

module Member
  # The Help desk tab of a project: the requests written from that project's sites (CYRA-940).
  # Flat name: a Member::Projects module would shadow the ::Projects models.
  class ProjectHelpdeskRequestsController < Member::BaseController
    SORT_COLUMNS = {
      "request" => "LOWER(helpdesk_requests.summary)",
      "status" => :status,
      "received" => :created_at
    }.freeze

    before_action :set_project

    def index
      @stats = @project.ticket_tally
      @status_counts = @project.helpdesk_requests.group(:status).count
      @filtering = search_q.present? || filter_ids(:status).any?
      @pagination = paginate(sorted(filtered_requests.order(created_at: :desc), columns: SORT_COLUMNS))
      @requests = @pagination.records
      # The public key is an ingest credential: only whoever manages the project's keys reads it.
      @can_read_tokens = can?("tokens.manage", scope: @project)
      @public_key = @project.tokens.active.order(:created_at).first&.public_key if @can_read_tokens
    end

    private

    # A request holds a visitor's address: seeing the project is not enough.
    def set_project
      @project = visible.projects.find(params[:project_id])
      require_permission!("helpdesk.manage", scope: @project)
    end

    # With no status chosen the list is the inbox: discarded requests stay one filter away.
    def filtered_requests
      scope = @project.helpdesk_requests.includes(:project)
      scope = scope.where(status: filter_ids(:status).presence || "received")
      return scope if search_q.blank?

      scope.where("helpdesk_requests.summary ILIKE ?", "%#{Helpdesk::Request.sanitize_sql_like(search_q)}%")
    end
  end
end
