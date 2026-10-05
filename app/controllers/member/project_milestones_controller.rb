# frozen_string_literal: true

module Member
  # Milestone di un progetto (Fase 4). Lookup project-scoped: lista/dettaglio leggibili da chi vede
  # il progetto; gestione (new/create/edit/update/destroy) admin/owner. Scoping anti-BOLA al progetto.
  # Controller flat (non Member::Projects::*) per non ombreggiare il namespace ::Projects (model).
  class ProjectMilestonesController < Member::BaseController
    permission_not_required "Traguardi di un progetto visibile: sola lettura, la gestione è gated più sotto.",
                            only: %i[index show]

    # Whitelist ordinamento (contratto Sortable#sorted). Progress resta statico (calcolo
    # in-memory batch, non una colonna); tickets = subquery COUNT sul milestone.
    SORT_COLUMNS = {
      "milestone" => "LOWER(projects_milestones.label)",
      "code" => :code,
      "due" => :due_on,
      "status" => :active,
      "tickets" => "(SELECT COUNT(*) FROM ticketing_tickets t WHERE t.milestone_id = projects_milestones.id)"
    }.freeze

    before_action :set_project
    before_action :require_management, only: %i[new create edit update destroy]
    before_action :set_milestone, only: %i[show edit update destroy]

    # Sortable columns of the tickets table on the milestone page.
    TICKET_SORT_COLUMNS = {
      "code" => :number,
      "title" => "LOWER(ticketing_tickets.title)",
      "kind" => :kind,
      "status" => { expr: "types_ticket_statuses.position", joins: :status },
      "weight" => :weight,
      "assignee" => { expr: "LOWER(accounts.name)", joins: :assignee }
    }.freeze

    STATUS_FILTERS = %w[active inactive].freeze

    def index
      @total_milestones = @project.milestones.count
      @query = params[:q].to_s.strip
      scope = searched_milestones(@project.milestones.ordered)
      # Exactly one status picked = a plain filtered list; otherwise inactive ones sink into a
      # closed group at the bottom, whatever the sort.
      statuses = Array(params[:status]) & STATUS_FILTERS
      @grouped = statuses.size != 1
      scope = scope.where(active: statuses.first == "active") unless @grouped
      @filtering = @query.present? || statuses.any?
      @inactive_count = scope.where(active: false).count if @grouped
      @pagination = paginate(first_by(sorted(scope, columns: SORT_COLUMNS), "projects_milestones.active DESC"))
      @milestones = @pagination.records
      @progress_by_id = Projects::Milestone.progress_for(@milestones.map(&:id))  # batch: niente N+1
      @stats = @project.ticket_tally
    end

    def show
      # CYRA-684 — i ticket di un obiettivo possono essere centinaia: a pagine.
      # Closed tickets sink into a closed group at the bottom, whatever the sort.
      tickets = @milestone.tickets.left_outer_joins(:status).includes(:project, :status, :priority, :assignee)
                          .order(created_at: :desc)
      done = Types::TicketStatus.categories[:done]
      @tickets_pagination = paginate(first_by(sorted(tickets, columns: TICKET_SORT_COLUMNS),
                                              "CASE WHEN types_ticket_statuses.category = #{done} THEN 1 ELSE 0 END"))
      @tickets = @tickets_pagination.records
      @progress = @milestone.progress
      @stats = @project.ticket_tally
      # Activity-log generalizzato: blocco Audit (ultimo evento) + cronologia nel modale.
      @activity_events = @milestone.activity_events.chronological.includes(:actor, :true_actor).to_a
      @last_activity = @activity_events.last
    end

    def new
      @milestone = @project.milestones.new(active: true, color: "indigo")
      @stats = @project.ticket_tally
    end

    def create
      @milestone = @project.milestones.new
      result = ::Projects::Milestones::Save.call(milestone: @milestone, attributes: milestone_params,
                                                 actor: Current.account, true_actor: Current.true_account)
      if result.ok?
        redirect_to member_project_milestones_path(@project), notice: t("member.milestones.created")
      else
        @errors = result.error.details || {}
        @stats = @project.ticket_tally
        render :new, status: :unprocessable_content
      end
    end

    def edit
      @stats = @project.ticket_tally
    end

    def update
      return toggle_active if request.format.json?

      result = ::Projects::Milestones::Save.call(milestone: @milestone, attributes: milestone_params,
                                                 actor: Current.account, true_actor: Current.true_account)
      if result.ok?
        redirect_to member_project_milestone_path(@project, @milestone), notice: t("member.milestones.updated")
      else
        @errors = result.error.details || {}
        @stats = @project.ticket_tally
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @milestone.destroy
      redirect_to member_project_milestones_path(@project), notice: t("member.milestones.deleted")
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def set_milestone
      @milestone = @project.milestones.find(params[:id])
    end

    def milestone_params
      params.permit(:code, :label, :color, :due_on, :active)
    end

    # The Active switch in Details saves on its own (fetch PATCH, no reload).
    def toggle_active
      result = ::Projects::Milestones::Save.call(milestone: @milestone, attributes: params.permit(:active),
                                                 actor: Current.account, true_actor: Current.true_account)
      head(result.ok? ? :no_content : :unprocessable_content)
    end

    def searched_milestones(scope)
      return scope if @query.blank?

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      scope.where("projects_milestones.label ILIKE :q OR projects_milestones.code ILIKE :q", q: pattern)
    end

    # Puts `expr` in front of whatever order the relation already has.
    def first_by(relation, expr)
      relation.reorder(Arel.sql(expr), *relation.order_values)
    end


    def require_management
      require_permission!("projects.edit", scope: @project)
    end
  end
end
