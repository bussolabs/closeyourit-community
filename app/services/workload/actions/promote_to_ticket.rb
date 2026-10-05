# frozen_string_literal: true

module Workload
  module Actions
    # Genera un ticket da una action riusando Ticketing::CreateTicket e salva il backlink
    # (action.ticket). Il progetto target è scelto dal chiamante (params[:project_id]) e risolto
    # nella VisibleScope del reporter (anti-BOLA → R404). Idempotente: una action già linkata non
    # rigenera. reporter = chi promuove. Pattern Ideas::PromoteToTicket.
    class PromoteToTicket < ApplicationService
      def initialize(action:, reporter:, params:, true_actor: nil)
        @action = action
        @reporter = reporter
        @params = params
        @true_actor = true_actor
      end

      def call
        return already_linked if @action.ticket.present?

        project = visible_project
        return project_not_found if project.nil?

        result = Ticketing::CreateTicket.call(
          organization: project.organization, reporter: @reporter, true_actor: @true_actor,
          params: ticket_params(project)
        )
        @action.update!(ticket: result.value) if result.ok?
        result
      end

      private

      # Progetto target risolto tra quelli visibili al reporter nell'org del team della action.
      def visible_project
        Authorization::VisibleScope
          .new(account: @reporter, organization: @action.team.organization)
          .projects.find_by(id: @params[:project_id])
      end

      def already_linked
        Result.err(AppError.new(I18n.t("workload.errors.already_linked"), code: "R422-WORKLOAD-003"))
      end

      def project_not_found
        Result.err(AppError.new(I18n.t("workload.errors.project_not_found"),
                                code: "R404-WORKLOAD-001", status: :not_found))
      end

      def ticket_params(project)
        {
          project_id: project.id,
          title: @params[:title].presence || @action.title,
          description: @params[:description],
          # Default `task`: una voce di carico di lavoro è lavoro da fare, non valore da progettare.
          kind: @params[:kind].presence || :task,
          status_id: @params[:status_id].presence || default_status(project.organization)&.id,
          priority_id: @params[:priority_id].presence || default_priority(project.organization)&.id
        }
      end

      def default_status(organization)
        organization.ticket_statuses.find_by(code: "open") ||
          organization.ticket_statuses.active.ordered.first
      end

      def default_priority(organization)
        organization.ticket_priorities.find_by(code: "medium") ||
          organization.ticket_priorities.active.ordered.first
      end
    end
  end
end
