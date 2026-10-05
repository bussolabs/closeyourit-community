# frozen_string_literal: true

module Member
  # Help desk: the requests written by the visitors of the projects' sites (CYRA-940).
  class HelpdeskRequestsController < Member::BaseController
    include Member::HelpdeskAccess

    SORT_COLUMNS = {
      "request" => "LOWER(helpdesk_requests.summary)",
      "project" => { expr: "LOWER(projects.name)", joins: :project },
      "status" => :status,
      "received" => :created_at
    }.freeze

    before_action :set_helpdesk_request, only: :show

    remembers_filters :status, :project_id, :q, :sort, only: :index

    def index
      @projects = helpdesk_projects
      return redirect_to(root_path, alert: t("member.forbidden")) if @projects.empty?

      @status_counts = helpdesk_requests.group(:status).count
      @filtering = search_q.present? || filter_ids(:status).any? || filter_ids(:project_id).any?
      @pagination = paginate(sorted(filtered_requests.order(created_at: :desc), columns: SORT_COLUMNS))
      @requests = @pagination.records
    end

    def show
      @messages = @request_record.messages.includes(:author)
      @similar = ::Helpdesk::FindSimilarRequests.call(request: @request_record).value
      @visit_errors = visit_error_groups
      return unless @request_record.open?

      # The first choices of the "join a ticket" field: tickets of the same project, most recent first.
      @linkable_tickets = ::Ticketing::LinkableTickets.call(scope: visible.tickets, project_ids: [ @request_record.project_id ])
    end

    private

    # CYRA-942 — the errors that happened during the same visit: the SDK button sends the visit id
    # that errors and replays carry. Scoped to the request's project.
    def visit_error_groups
      return ::Errors::Group.none if @request_record.session_id.blank?

      ids = ::Errors::Event.where(project_id: @request_record.project_id, replay_session_id: @request_record.session_id)
                           .distinct.pluck(:group_id)
      @request_record.project.error_groups.where(id: ids).recent.limit(5)
    end

    # With no status chosen the list is the inbox: discarded requests stay one filter away.
    def filtered_requests
      scope = helpdesk_requests.includes(:project)
      scope = scope.where(status: filter_ids(:status).presence || "received")
      scope = scope.where(project_id: filter_ids(:project_id)) if filter_ids(:project_id).any?
      return scope if search_q.blank?

      scope.where("helpdesk_requests.summary ILIKE ?", "%#{Helpdesk::Request.sanitize_sql_like(search_q)}%")
    end
  end
end
