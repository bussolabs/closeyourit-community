# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      # CYRA-1030 — «Rimanda allo staging» un rilascio fermo in produzione. Gemello di
      # ProductionHoldsController: stessa forma, stessa autorizzazione (CTO effettivo, dentro il service).
      class StagingSendBacksController < BaseController
        def create
          workflow = workflow_for(params[:ticket_id])
          result = ::Agents::Workflows::SendBackToStaging.call(workflow:, actor: Current.account)
          redirect_to_automation(workflow.ticket, result, "member.tickets.automation.blocked.sent_back")
        end
      end
    end
  end
end
