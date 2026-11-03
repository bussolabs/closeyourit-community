# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-1148 — fills the ticket codes of a page's rendered text with title and status: one request
    # per page (`ticket-refs` controller), one ticket query for every code. Only `visible.tickets`
    # answer, so a code of a hidden project gets nothing back and stays plain text.
    class ReferencesController < Member::BaseController
      permission_not_required "Shows title and status of tickets the reader already sees: no data beyond " \
                              "their own pages."

      LIMIT = 100

      def index
        labels = tickets.to_h { |ticket| [ ticket.code, Ui::TicketRefComponent.new(ticket:).render_in(view_context) ] }

        render json: { data: labels }
      end

      private

      def references
        params[:codes].to_s.split(",").first(LIMIT).filter_map { |code| ::Ticketing::CodeReference.parse(code) }.uniq
      end

      # Key and number in one query: CodeReference.resolve would look the projects up first.
      def tickets
        refs = references
        return [] if refs.empty?

        conditions = refs.map { "(projects.key = ? AND ticketing_tickets.number = ?)" }.join(" OR ")
        visible.tickets.eager_load(:project, :status).where(conditions, *refs.flat_map { [ it.key, it.number ] })
      end
    end
  end
end
