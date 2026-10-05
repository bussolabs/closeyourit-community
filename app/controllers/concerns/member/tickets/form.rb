# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-739 — il MODULO del ticket (nuovo e modifica): le opzioni dei select, il progetto bloccato
    # quando si apre da un progetto, le piattaforme già spuntate. Le query stanno in
    # Ticketing::FormOptions; qui resta il pezzo che riguarda la richiesta in corso.
    module Form
      extend ActiveSupport::Concern

      included do
        before_action :load_form_options, only: %i[list show new create edit update]
      end

      private

      # Opzioni dei select del modulo (CYRA-739 → Ticketing::FormOptions). Assegnate una per una: le
      # view le leggono con questi nomi da sempre, e cercare `@epics` deve portare qui.
      def load_form_options
        options = Ticketing::FormOptions.call(organization: Current.organization,
                                              projects: visible.projects, ticket: @ticket,
                                              signals: %w[new create].include?(action_name))
        @projects = options.projects
        @statuses = options.statuses
        @priorities = options.priorities
        @assignees = @reviewers = options.assignees
        @platforms = options.platforms
        @project_platforms_map = options.project_platforms_map
        @milestones = options.milestones
        @milestones_project_map = options.milestones_project_map
        @milestone_projects = options.milestone_projects
        @epics = options.epics
        @epics_project_map = options.epics_project_map
        @error_groups = promotable(options.error_groups, "errors.promote")
        @error_groups_project_map = options.error_groups_project_map
        @metric_groups = promotable(options.metric_groups, "metrics.promote")
        @metric_groups_project_map = options.metric_groups_project_map
      end

      # Only the signals of projects where the account may promote: offering a choice the save
      # would silently drop is worse than not offering it.
      def promotable(groups, permission)
        return groups if groups.empty?

        allowed = @projects.select { |project| can?(permission, scope: project) }.to_set(&:id)
        groups.select { |group| allowed.include?(group.project_id) }
      end

      def preselected_platform_ids
        # simplecov:disable @ticket è sempre assegnato (new/create) prima di questa chiamata → `@ticket&` else irraggiungibile
        project_id = @ticket&.project_id
        # simplecov:enable
        Ticketing::FormOptions.preselected_platform_ids(organization: Current.organization,
                                                        account: Current.account, project_id: project_id)
      end

      # Ticket aperto da un progetto specifico (?project_id=): blocca il progetto nel form e
      # restringe le opzioni piattaforma a quelle del progetto. nil → form normale (select aperto).
      def lock_project(project_id)
        return if project_id.blank?

        project = Current.organization.projects.find_by(id: project_id)
        return if project.nil?

        @platforms = project.platforms.active.ordered
        project
      end
    end
  end
end
