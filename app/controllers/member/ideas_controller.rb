# frozen_string_literal: true

module Member
  # Organization ideas, scoped through visible projects (anti-BOLA via visible.ideas). Every role
  # proposes, votes and comments; managing someone else's idea needs ideas.edit/delete.
  class IdeasController < Member::BaseController
    permission_not_required "Proposing an idea and browsing visible ones is baseline; managing other " \
                            "people's ideas is gated below.",
                            only: %i[index new create duplicates]

    # Sortable#sorted whitelist. Default order (no param) is last activity, newest first. CYRA-360
    SORT_COLUMNS = {
      "title" => "LOWER(ideas_ideas.title)",
      "project" => { expr: "LOWER(projects.name)", joins: :project },
      "author" => { expr: "LOWER(accounts.name)", joins: :author },
      "votes" => :votes_count,
      "comments" => :comments_count,
      "status" => :status,
      "ticket" => { expr: "ticketing_tickets.number", joins: :ticket },
      "last_activity" => :updated_at
    }.freeze

    include Member::IdeaShowContext

    before_action :set_idea, only: %i[show edit update destroy archive reopen]
    before_action :require_idea_permission, only: %i[edit update destroy archive reopen]

    # Remembered filters, per address (see RememberableFilters). CYRA-694
    remembers_filters :status, :project_id, :q, :sort, :view, only: :index

    def index
      @status_counts = visible.ideas.group(:status).count
      @pagination = filtered_ideas
      @ideas = @pagination.records
      @saved_views = saved_views_for("ideas")
      @projects = visible.projects.order(:name)
      @query = search_q
      # "No ideas" and "no matches" differ; the total is the unfiltered one of the chips. CYRA-555
      @filtering = search_q.present? || filter_ids(:status).any? || filter_ids(:project_id).any?
      @total_ideas = @status_counts.values.sum
      # Search mode shown above results: true = by meaning (default), false = exact words. CYRA-167
      @semantic_mode = semantic_search?
      @ideas_view = params[:view] == "cards" ? "cards" : "table"
    end

    def show
      load_idea_show_context
    end

    def new
      # "Propose evolution": the base idea locks the project. CYRA-845
      @base = lock_base(params[:evolves_id])
      @idea = ::Ideas::Idea.new(project_id: @base&.project_id || params[:project_id])
      @projects = visible.projects.order(:name)
      @locked_project = @base&.project || lock_project(params[:project_id])
    end

    def create
      result = ::Ideas::CreateIdea.call(
        organization: Current.organization, author: Current.account, params: idea_attributes,
        true_actor: Current.true_account
      )
      if result.ok?
        redirect_to member_idea_path(result.value), notice: t("member.ideas.created")
      else
        @base = lock_base(idea_params[:evolves_id])
        @idea = ::Ideas::Idea.new(idea_attributes.except(:evolves_id))
        @projects = visible.projects.order(:name)
        @locked_project = @base&.project || lock_project(params[:locked_project].present? ? idea_params[:project_id] : nil)
        @errors = result.error.details || {}
        flash.now[:alert] = result.error.message
        render :new, status: :unprocessable_content
      end
    end

    # Ideas similar to the draft (JSON for the new form), across visible projects. On error the JS
    # hides the panel and proposing stays possible. CYRA-167
    def duplicates
      result = ::Ideas::FindSimilarIdeas.call(scope: visible.ideas, text: params[:text].to_s)
      if result.ok?
        render json: { data: { ideas: result.value.map { |idea| duplicate_payload(idea) } } }
      else
        render json: { error: { code: result.error.code, message: result.error.message } },
               status: result.error.status
      end
    end

    def edit
      return if @idea.status_open?

      # A frozen idea is not editable: the show page explains why.
      redirect_to member_idea_path(@idea), alert: t("ideas.errors.locked")
    end

    def update
      result = ::Ideas::UpdateIdea.call(idea: @idea, params: idea_attributes,
                                        actor: Current.account, true_actor: Current.true_account)
      if result.ok?
        redirect_to member_idea_path(@idea), notice: t("member.ideas.updated")
      else
        @errors = result.error.details || {}
        flash.now[:alert] = result.error.message
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @idea.destroy
      redirect_to member_ideas_path, notice: t("member.ideas.deleted")
    end

    def archive
      result = ::Ideas::ChangeStatus.call(idea: @idea, to: :archived,
                                          actor: Current.account, true_actor: Current.true_account)
      respond_change(result, t("member.ideas.archived"))
    end

    def reopen
      result = ::Ideas::ChangeStatus.call(idea: @idea, to: :open,
                                          actor: Current.account, true_actor: Current.true_account)
      respond_change(result, t("member.ideas.reopened"))
    end

    private

    # Anti-BOLA: another org's idea or a hidden project raises RecordNotFound.
    def set_idea
      @idea = visible.ideas.find(params[:id])
    end

    # ?project_id= locks the project in the form; a hidden project returns nil (anti-BOLA).
    def lock_project(project_id)
      return if project_id.blank?

      visible.projects.find_by(id: project_id)
    end

    # Base of an evolution: visible and not itself an evolution (one level only, as the service
    # enforces), so the form never starts out doomed.
    def lock_base(idea_id)
      return if idea_id.blank?

      base = visible.ideas.find_by(id: idea_id)
      base unless base&.evolution?
    end

    # Authors always manage their own idea; other people's ideas need the dedicated key.
    def require_idea_permission
      note_permission_check! # Decided here even when no key is involved. CYRA-727
      return if @idea.authored_by?(Current.account)

      key = action_name == "destroy" ? "ideas.delete" : "ideas.edit"
      require_permission!(key, scope: @idea.project)
    end

    def filtered_ideas
      # Preloads for the ticket code column and the evolution chip. CYRA-370, CYRA-747, CYRA-845
      scope = visible.ideas.includes(:project, :author, :evolution_link, ticket: :project)
      scope = scope.where(status: filter_ids(:status)) if filter_ids(:status).any?
      scope = scope.where(project_id: filter_ids(:project_id)) if filter_ids(:project_id).any?
      paginate(searched(sorted(scope.by_last_activity, columns: SORT_COLUMNS)))
    end

    # By meaning (default, ordered by relevance) or exact words (semantic=0). If embeddings are
    # down it falls back to exact words and flags @semantic_degraded, never an error. CYRA-167
    def searched(scope)
      return scope if search_q.blank?
      return like_search(scope) unless semantic_search?

      result = ::Ideas::SemanticSearch.call(scope: scope, query: search_q)
      if result.err?
        @semantic_degraded = true
        return like_search(scope)
      end

      # Semantic matches first, then text matches: a fresh idea has no embedding yet and would
      # otherwise vanish even when searched by its exact title.
      ordered_ids = result.value + (text_match_ids(scope) - result.value)
      return scope.none if ordered_ids.empty?

      # Relevance wins over any column sort: in_order_of filters and orders by the given ids.
      scope.reorder(nil).in_order_of(:id, ordered_ids)
    end

    def like_search(scope)
      scope.where(
        "ideas_ideas.title ILIKE :q OR ideas_ideas.problem ILIKE :q OR ideas_ideas.solution ILIKE :q",
        q: "%#{search_q}%"
      )
    end

    # Text-matching ids: safety net for ideas whose embedding is not computed yet.
    def text_match_ids(scope)
      like_search(scope).reorder(nil).pluck(:id)
    end

    # "0" = exact words; missing or "1" = by meaning. Single source for search, banner and toolbar.
    def semantic_search?
      params[:semantic] != "0"
    end

    # "Similar ideas" row: enough to spot a duplicate without opening it.
    def duplicate_payload(idea)
      { id: idea.id, title: idea.title, project: idea.project.name,
        status_label: t("member.ideas.status.#{idea.status}"), votes_count: idea.votes_count,
        url: member_idea_path(idea) }
    end

    def idea_params
      params.permit(:project_id, :title, :problem, :solution, :monetization, :risks, :evolves_id)
    end

    # Comma-separated stakeholders become an array; the model strips and dedups. project_id is
    # ignored on update (attr_readonly).
    def idea_attributes
      idea_params.merge(stakeholders: params[:stakeholders].to_s.split(","))
    end

    def respond_change(result, notice)
      if result.ok?
        redirect_back fallback_location: member_idea_path(@idea), notice: notice
      else
        redirect_back fallback_location: member_idea_path(@idea), alert: result.error.message
      end
    end
  end
end
