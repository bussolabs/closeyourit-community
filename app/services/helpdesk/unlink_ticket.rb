# frozen_string_literal: true

module Helpdesk
  # Undoes a link made by mistake: the request goes back among the new ones (CYRA-941). A request
  # that became a ticket stays as it is: the ticket exists.
  class UnlinkTicket < ApplicationService
    def initialize(request:)
      @request = request
    end

    def call
      @request.update!(ticket: nil, status: back_to) if @request.status_linked?
      Result.ok(@request)
    end

    private

    # Back where it was before the link: answered if the team already wrote to the visitor.
    def back_to = @request.messages.any?(&:direction_outbound?) ? :answered : :received
  end
end
