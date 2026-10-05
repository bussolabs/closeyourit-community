# frozen_string_literal: true

module Cli
  module V1
    module Workload
      # Board del carico di lavoro non-dev via CLI, team-scoped. Nessuna permission key: l'autorizzazione
      # è l'appartenenza al team → visible_actions è sia il confine di lettura sia di scrittura (action di
      # un team altrui → RecordNotFound → R404, mai 403). Model SEMPRE ::Workload::* fully-qualified.
      class ActionsController < Cli::V1::BaseController
        before_action :set_action, only: %i[show update destroy]

        def index
          records, meta = paginate(visible_actions.order(created_at: :desc))
          render_ok(WorkloadActionSerializer.new(records), meta: meta)
        end

        def show
          render_ok(WorkloadActionSerializer.new(@action))
        end

        def create
          action = ::Workload::Action.new(team: current_teams.find_by(id: params[:team_id]))
          render_result(::Workload::Actions::Save.call(action: action, attributes: action_params,
                                                       participant_ids: params[:participant_ids], actor: Current.account),
                        created: true)
        end

        def update
          render_result(::Workload::Actions::Save.call(action: @action, attributes: action_params,
                                                       participant_ids: params[:participant_ids], actor: Current.account))
        end

        def destroy
          @action.destroy
          render_no_content
        end

        private

        def visible_actions
          ::Workload::Action.visible_to(account: Current.account, organization: Current.organization)
                            .includes(:team, :participants, :ticket, :created_by)
        end

        def current_teams
          Current.account.teams.where(organization_id: Current.organization.id)
        end

        def set_action
          @action = visible_actions.find(params[:id])
        end

        def action_params
          permitted = params.permit(:title, :description, :status, :scheduled_at, :due_at, :ticket_id)
          permitted[:ticket_id] = sanitized_ticket_id(permitted[:ticket_id]) if permitted.key?(:ticket_id)
          permitted
        end

        # Un ticket linkabile deve essere in un progetto visibile all'utente (anti-BOLA).
        def sanitized_ticket_id(ticket_id)
          return nil if ticket_id.blank?

          visible = ::Ticketing::Ticket.where(project_id: visible_projects.select(:id))
          visible.exists?(id: ticket_id) ? ticket_id : nil
        end

        def render_result(result, created: false)
          if result.ok?
            serialized = WorkloadActionSerializer.new(result.value)
            created ? render_created(serialized) : render_ok(serialized)
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end
      end
    end
  end
end
