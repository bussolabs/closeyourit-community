# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      class CancellationsController < BaseController
        def create
          workflow = workflow_for(params[:ticket_id])
          result = ::Agents::Workflows::Cancel.call(workflow:, actor: Current.account, reason: params[:reason])
          redirect_to_automation(workflow.ticket, result, "member.tickets.automation.cancelled_notice")
        end
      end
    end
  end
end
