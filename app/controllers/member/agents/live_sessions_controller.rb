# frozen_string_literal: true

module Member
  module Agents
    # CYRA-1138 — watch an automator attempt live: the files the agent touches, its changes in review style,
    # its latest steps. agents.view is per organization and tickets are per project, so every attempt here
    # is filtered to the tickets the viewer can see. New steps arrive as a signal and the page reloads its
    # frame with the viewer's own session (Agents::LiveEvents::Broadcast). A conflict with another agent of the
    # project shows as a notice at the bottom right.
    class LiveSessionsController < Member::BaseController
      SIDEBAR_SIZE = 20

      before_action :require_view

      def index
        latest = live_scope.status_running.order(started_at: :desc).first
        return redirect_to(member_agents_live_session_path(latest)) if latest

        @sessions = []
      end

      def show
        @attempt = live_scope.includes(:host, workflow: { ticket: :project }).find(params[:id])
        @ticket = @attempt.workflow.ticket
        @session = ::Agents::LiveEvents::Session.new(attempt: @attempt)
        @code_available = @ticket.project.automator_live_code_enabled? && @session.code?
        @code_view = @code_available && params[:view] != "files"
        @following = params[:file].blank? || @session.file(params[:file]).nil?
        @current_path = @following ? @session.followed_path : params[:file]
        @sessions = sidebar_sessions
        @colors = ::Agents::LiveEvents::ProjectView.colors(@sessions)
        @conflicts = conflicts
        @can_pause = can?("tickets.edit", scope: @ticket.project)
        load_tree
        render(partial: "frame", layout: false) if turbo_frame_request_id == ::Agents::LiveEvents::Broadcast::FRAME
      end

      # One closed folder of the project tree, loaded when the viewer opens it.
      def tree
        @attempt = live_scope.includes(workflow: { ticket: :project }).find(params[:id])
        @ticket = @attempt.workflow.ticket
        @session = ::Agents::LiveEvents::Session.new(attempt: @attempt)
        @colors = ::Agents::LiveEvents::ProjectView.colors(sidebar_sessions)
        load_tree
        @dir = params[:dir].to_s
        @depth = params[:depth].to_i.clamp(0, 50)
        render partial: "tree_frame", layout: false
      end

      private

      def live_scope
        ::Agents::Attempt.where(organization: current_organization)
                         .joins(:workflow).where(agents_workflows: { ticket_id: visible.tickets.select(:id) })
      end

      # The sessions at work, plus the one open even when it is over, so the sidebar always shows where you are.
      def sidebar_sessions
        running = live_scope.status_running.includes(:host, workflow: { ticket: :project }).order(started_at: :desc).limit(SIDEBAR_SIZE).to_a
        running.any? { it.id == @attempt.id } ? running : [ @attempt, *running ]
      end

      # CYRA-1139 — the files this agent and another agent of the same project are both changing right now.
      def conflicts
        return [] unless @attempt.status_running?

        others = live_scope.status_running.where.not(id: @attempt.id)
                           .where(agents_workflows: { ticket_id: @ticket.project.tickets.select(:id) })
                           .includes(:host, workflow: { ticket: :project }).to_a
        ::Agents::LiveEvents::ProjectView.new(attempts: [ @attempt, *others ]).conflicts_with(@attempt)
      end

      # CYRA-1138 — the whole project from GitHub, with the files the agent created merged in; nil keeps the touched-only list.
      def load_tree
        @tree = ::Agents::LiveEvents::ProjectTree.call(project: @ticket.project)
        return unless @tree

        @tree_index = ::Agents::LiveEvents::ProjectTree::Index.new(@tree.paths | @session.files.map(&:path))
        @open_dirs = @session.files.flat_map { folders_above(it.path) }.to_set
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
