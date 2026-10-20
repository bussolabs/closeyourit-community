# frozen_string_literal: true

module Ticketing
  # Names another reporter on an existing ticket, e.g. the client a ticket was typed in for
  # (CYRA-1086). The new reporter must see the project and becomes a watcher; the old one stays one.
  class SetReporter < ApplicationService
    def initialize(organization:, ticket:, reporter_id:, actor: nil, true_actor: nil)
      @organization = organization
      @ticket = ticket
      @reporter_id = reporter_id
      @actor = actor
      @true_actor = true_actor
    end

    def call
      reporter = @reporter_id.blank? ? nil : @organization.accounts.find_by(id: @reporter_id)
      return Result.ok(@ticket) if reporter && reporter.id == @ticket.reporter_id
      return not_allowed unless @ticket.project.reporter_candidate?(reporter)

      from_name = @ticket.reporter.name
      ApplicationRecord.transaction do
        @ticket.update!(reporter: reporter)
        Subscription.ensure_for(ticket: @ticket, account: reporter, source: :reporter)
        RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor, action: "reporter_changed",
                            data: { reporter: { from: from_name, to: reporter.name } })
      end
      broadcast_reporter
      Result.ok(@ticket)
    end

    private

    def not_allowed
      Result.err(AppError.new(I18n.t("member.tickets.errors.reporter_not_allowed"), code: "R422-TICKET-023"))
    end

    def broadcast_reporter
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.ticket(@ticket),
        target: "#{ActionView::RecordIdentifier.dom_id(@ticket)}_reporter",
        partial: "member/tickets/reporter",
        locals: { ticket: @ticket }
      )
    end
  end
end
