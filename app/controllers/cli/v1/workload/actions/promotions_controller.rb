# frozen_string_literal: true

module Cli
  module V1
    module Workload
      module Actions
        # Genera un ticket da una workload action via CLI (POST). Riusa Workload::Actions::PromoteToTicket:
        # progetto target risolto nella VisibleScope del reporter (R404 se non visibile), idempotente
        # sull'action già linkata (R422-WORKLOAD-003). Ritorna il ticket creato (201). Team-scoped:
        # action di un altro team → RecordNotFound → R404.
        class PromotionsController < Cli::V1::BaseController
          before_action :set_action

          def create
            result = ::Workload::Actions::PromoteToTicket.call(
              action: @action, reporter: Current.account, true_actor: Current.true_account, params: promotion_params
            )
            if result.ok?
              render_created(TicketSerializer.new(result.value))
            else
              render_error(result.error.code, result.error.message,
                           status: result.error.status, details: result.error.details)
            end
          end

          private

          def set_action
            @action = ::Workload::Action.visible_to(account: Current.account, organization: Current.organization)
                                        .find(params[:action_id])
          end

          def promotion_params
            params.permit(:project_id, :title, :description, :kind, :status_id, :priority_id)
          end
        end
      end
    end
  end
end
