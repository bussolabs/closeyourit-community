# frozen_string_literal: true

module Member
  module Tickets
    class AutomationsController < Member::BaseController
      permission_not_required "Stato dell'automazione di un ticket visibile: sola lettura, il confine è la " \
                              "visibilità del ticket."

      def show
        ticket = visible.tickets.find(params[:ticket_id])
        render json: AgentWorkflowSerializer.new(ticket.agent_workflow).as_json
      end
    end
  end
end
