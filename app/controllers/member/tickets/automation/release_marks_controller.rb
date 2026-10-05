# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      # CYRA-624 — «segna come rilasciato»: l'uscita per quando sai tu che il rilascio è a posto e la
      # macchina non riesce a vederlo. Gemello degli altri gate: stessa forma, stessa autorizzazione
      # (CTO effettivo, dentro il service).
      class ReleaseMarksController < BaseController
        def create
          workflow = workflow_for(params[:ticket_id])
          result = ::Agents::Probes::MarkReleased.call(workflow:, actor: Current.account)
          redirect_to_automation(workflow.ticket, result, "member.tickets.automation.proof.marked")
        end
      end
    end
  end
end
