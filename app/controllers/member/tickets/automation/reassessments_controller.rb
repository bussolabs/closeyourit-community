# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      # CYRA-675 — «Rivaluta»: rimanda la lavorazione alla pianificazione perché rilegga il codice di
      # oggi e dica se il lavoro serve ancora. Gemello degli altri gate: stessa forma, stessa
      # autorizzazione (CTO effettivo, dentro il service).
      class ReassessmentsController < BaseController
        def create
          workflow = workflow_for(params[:ticket_id])
          result = ::Agents::Workflows::Reassess.call(workflow:, actor: Current.account)
          redirect_to_automation(workflow.ticket, result, "member.tickets.automation.reassess.requested")
        end
      end
    end
  end
end
