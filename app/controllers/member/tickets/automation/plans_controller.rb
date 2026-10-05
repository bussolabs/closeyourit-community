# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      class PlansController < BaseController
        def show
          ticket = visible.tickets.find(params[:ticket_id])
          plan = ticket.agent_workflow&.plans&.last or raise ActiveRecord::RecordNotFound
          body = ::Agents::Plans::Markdown.call(plan:, ticket:)

          send_data body, type: "text/markdown; charset=utf-8", disposition: "attachment",
                          filename: "#{ticket.code}-piano-v#{plan.version}.md"
        end
      end
    end
  end
end
