# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      class ChangeRequestsController < BaseController
        def create
          workflow = workflow_for(params[:ticket_id])
          result = ::Agents::Workflows::RequestPlanChanges.call(
            workflow:, actor: Current.account, reason: params[:reason]
          )
          redirect_to_automation(workflow.ticket, result, "member.tickets.automation.plan.changes_notice")
        end
      end
    end
  end
end
