# frozen_string_literal: true

module Telegram
  # /ticket CODICE (es. /ticket DRRA-12): mostra stato, priorità e assegnatario di un ticket visibile.
  class ShowTicket < ApplicationService
    include Telegram::Respondable

    def initialize(account:, chat_id:, code:)
      @account = account
      @chat_id = chat_id
      @code = code.to_s.strip
    end

    def call
      return usage if @code.blank?

      result = Telegram::ResolveTicket.call(account: @account, code: @code)
      unless result.ok?
        reply_text(result.error.message)
        return result
      end

      ticket = result.value
      reply("ticket.show",
            code: ticket.code, title: ticket.title,
            status: ticket.status.label, priority: ticket.priority.label,
            assignee: ticket.assignee&.name.presence || t("ticket.unassigned"),
            url: ticket_url(ticket))
      Result.ok(ticket)
    end

    private

    def usage
      reply("ticket.show_usage")
      Result.err(AppError.new("codice ticket mancante", code: "R422-TELEGRAM-007"))
    end
  end
end
