# frozen_string_literal: true

module Telegram
  # /miei-ticket: elenca i ticket aperti segnalati dall'account (reporter), tra i progetti visibili,
  # i 10 più recenti. Anti-BOLA: solo ticket di progetti ancora visibili all'account.
  class ListMyTickets < ApplicationService
    include Telegram::Respondable
    include Telegram::VisibleProjects

    LIMIT = 10

    def initialize(account:, chat_id:)
      @account = account
      @chat_id = chat_id
    end

    def call
      tickets = open_reported_tickets
      if tickets.empty?
        reply("ticket.mine_empty")
      else
        lines = tickets.map { |ticket| t("ticket.mine_item", code: ticket.code, title: ticket.title, status: ticket.status.label) }
        reply("ticket.mine", list: lines.join("\n"))
      end
      Result.ok(:listed)
    end

    private

    def open_reported_tickets
      visible_ids = all_visible_projects(@account).map(&:id)
      return [] if visible_ids.empty?

      Ticketing::Ticket.where(reporter: @account, project_id: visible_ids)
                       .joins(:status).where(types_ticket_statuses: { category: open_categories })
                       .includes(:status, :project)
                       .order(created_at: :desc).limit(LIMIT).to_a
    end

    # Aperti = category open o in_progress (esclude i done/chiusi).
    def open_categories
      categories = Types::TicketStatus.categories
      [ categories[:open], categories[:in_progress] ]
    end
  end
end
