# frozen_string_literal: true

module Member
  module Agents
    # CYRA-1172 — watch a project live: every agent at work on it, the whole project tree with the files they
    # change, their changes in review style, their latest steps, and an optional filter on one agent. agents.view
    # is per organization and tickets are per project, so every attempt here is filtered to the tickets the
    # viewer can see. New steps arrive as a signal and the page reloads its frame with the viewer's own session
    # (Agents::LiveEvents::Broadcast). A session URL opens its project with that agent filtered.
    class LiveSessionsController < Member::BaseController
      SIDEBAR_SIZE = 20

      before_action :require_view

      def index
        latest = live_scope.status_running.includes(workflow: :ticket).order(started_at: :desc).first
        return redirect_to(project_member_agents_live_sessions_path(latest.workflow.ticket.project_id)) if latest

        @projects = []
        # CYRA-1173 — counted only when nothing is at work: the same number as Approvals in the sidebar.
        @awaiting_count = ::Home::Approvals::Queue.awaiting_count(account: Current.account, organization: current_organization,
                                                                  visible_projects: visible.projects, visible_tickets: visible.tickets)
      end

      def show
        attempt = live_scope.includes(workflow: :ticket).find(params[:id])
        redirect_to project_member_agents_live_sessions_path(attempt.workflow.ticket.project_id, agent: attempt.id,
                                                             file: params[:file].presence, view: params[:view].presence)
      end

      def project
        load_project
        @code_available = @project.automator_live_code_enabled? && @shown.any? { it.session.code? }
        @code_view = @code_available && params[:view] != "files"
        @files = @shown_files
        @current_path = @files.find { it.path == params[:file] }&.path || followed_path
        @following = params[:file].blank? || @current_path != params[:file]
        @timeline = @shown.flat_map { |agent| agent.session.timeline.map { [ agent, it ] } }
                          .sort_by { |_, step| step.at }.reverse.first(::Agents::LiveEvents::Session::TIMELINE_SIZE)
        @conflicts = @agent ? @view.conflicts_with(@agent.attempt) : @view.conflicts
        @can_pause = can?("tickets.edit", scope: @project)
        @projects = sidebar_projects
        render(partial: "frame", layout: false) if turbo_frame_request_id == ::Agents::LiveEvents::Broadcast::FRAME
      end

      # One closed folder of the project tree, loaded when the viewer opens it.
      def project_tree
        load_project
        @files = @shown_files
        @dir = params[:dir].to_s
        @depth = params[:depth].to_i.clamp(0, 50)
        render partial: "tree_frame", layout: false
      end

      private

      def live_scope
        ::Agents::Attempt.where(organization: current_organization)
                         .joins(:workflow).where(agents_workflows: { ticket_id: visible.tickets.select(:id) })
      end

      # The agents at work on the project, plus the filtered one even when it is over.
      def load_project
        @project = visible.projects.find(params[:project_id])
        scope = live_scope.where(agents_workflows: { ticket_id: @project.tickets.select(:id) }).includes(:host, workflow: { ticket: :project })
        attempts = scope.status_running.order(started_at: :desc).limit(SIDEBAR_SIZE).to_a
        if params[:agent].present? && attempts.none? { it.id == params[:agent] }
          filtered = scope.find_by(id: params[:agent])
          attempts << filtered if filtered
        end
        @view = ::Agents::LiveEvents::ProjectView.new(attempts:)
        @agent = @view.agents.find { it.attempt.id == params[:agent] }
        @shown = @agent ? [ @agent ] : @view.agents
        @shown_files = @view.files.filter_map do |file|
          touches = file.touches.select { |touch| @shown.include?(touch.agent) }
          file.with(touches:) if touches.any?
        end
        load_tree
      end

      # The file the agents changed last, so the page follows the work.
      def followed_path
        @files.max_by { |file| file.touches.map { it.entry.changes.last.at }.max }&.path
      end

      def sidebar_projects
        live_scope.status_running.joins(workflow: :ticket).group(::Ticketing::Ticket.arel_table[:project_id]).count
                  .then { |counts| visible.projects.where(id: counts.keys).order(:name).map { [ it, counts[it.id] ] } }
      end

      # CYRA-1138 — the whole project from GitHub with the files the agents created merged in; nil keeps the touched-only list.
      def load_tree
        @tree = ::Agents::LiveEvents::ProjectTree.call(project: @project)
        return unless @tree

        @tree_index = ::Agents::LiveEvents::ProjectTree::Index.new(@tree.paths | @shown_files.map(&:path))
        @open_dirs = @shown_files.flat_map { folders_above(it.path) }.to_set
        @dir_agents = @shown_files.each_with_object(Hash.new { |hash, dir| hash[dir] = [] }) do |file, dirs|
          folders_above(file.path).each { |dir| dirs[dir] |= file.agents }
        end
      end

      def folders_above(path)
        dir = ::Agents::LiveEvents::ProjectTree::Index.parent_of(path)
        dir.empty? ? [] : [ dir, *folders_above(dir) ]
      end

      def require_view
        return if can_view_agents?

        require_permission!("agents.view")
      end
    end
  end
end
