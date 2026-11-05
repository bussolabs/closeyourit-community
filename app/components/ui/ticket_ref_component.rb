# frozen_string_literal: true

module Ui
  # A ticket cited in free text: code, short title and status, as one link to the ticket (CYRA-1148).
  # Rendered only by Member::Tickets::ReferencesController, for tickets the reader can see; the
  # markdown keeps just the code, so a hidden ticket never reaches the browser.
  class TicketRefComponent < BaseComponent
    TITLE_LENGTH = 40

    def initialize(ticket:)
      @ticket = ticket
    end

    private

    def href
      Rails.application.routes.url_helpers.member_ticket_path(@ticket)
    end

    def short_title
      @ticket.title.to_s.truncate(TITLE_LENGTH)
    end
  end
end
