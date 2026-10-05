# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      # Riprova una lavorazione fermata dal tetto ai tentativi di revisione (CYRA-218). Gemello degli
      # altri gate: stessa forma, stessa autorizzazione (CTO effettivo, dentro il service).
      class UnblocksController < BaseController
        def create
          workflow = workflow_for(params[:ticket_id])
          result = ::Agents::Workflows::Unblock.call(workflow:, actor: Current.account)
          redirect_to_automation(workflow.ticket, result, "member.tickets.automation.blocked.retried")
        end
      end
    end
  end
end
