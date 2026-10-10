# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      class RestartsController < BaseController
        def create
          workflow = workflow_for(params[:ticket_id])
          result = ::Agents::Workflows::Restart.call(workflow:, actor: Current.account)
          redirect_to_automation(workflow.ticket, result, "member.tickets.automation.restarted_notice")
        end
      end
    end
  end
end
