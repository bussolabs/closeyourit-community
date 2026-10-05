# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      # CYRA-871 — «Ferma» un rilascio che aspetta la produzione. Gemello degli altri gate: stessa forma,
      # stessa autorizzazione (CTO effettivo, dentro il service).
      class ProductionHoldsController < BaseController
        def create
          workflow = workflow_for(params[:ticket_id])
          result = ::Agents::Workflows::HoldProduction.call(workflow:, actor: Current.account)
          redirect_to_automation(workflow.ticket, result, "member.tickets.automation.production_hold.held")
        end
      end
    end
  end
end
