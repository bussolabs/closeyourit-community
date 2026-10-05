# frozen_string_literal: true

module Helpdesk
  # Joins a new request to a ticket that already exists in the same project (CYRA-941): ten people
  # reporting the same fault make one ticket.
  class LinkToTicket < ApplicationService
    def initialize(request:, ticket:)
      @request = request
      @ticket = ticket
    end

    def call
      return err("R422-HELPDESK-002", :already_handled) unless @request.open?
      return err("R422-HELPDESK-003", :ticket_not_found) if @ticket.nil? || @ticket.project_id != @request.project_id

      @request.update!(ticket: @ticket, status: :linked)
      Result.ok(@request)
    end

    private

    def err(code, key) = Result.err(AppError.new(I18n.t("member.helpdesk.errors.#{key}"), code: code))
  end
end
