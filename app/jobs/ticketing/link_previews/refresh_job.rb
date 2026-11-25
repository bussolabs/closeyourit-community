# frozen_string_literal: true

module Ticketing
  module LinkPreviews
    # After a save, reads the links of the description as it is NOW, not as it was when the job was
    # queued: a job left behind by an earlier edit never brings back a removed link (CYRA-1163).
    # On the `seo` lane, the one that visits other people's sites; one job per ticket at a time.
    # When a card was read, the cards of the open ticket page are replaced live: the job usually ends
    # after the page of the save was already rendered.
    class RefreshJob < ApplicationJob
      queue_as :seo

      limits_concurrency to: 1, key: ->(ticket_id:) { "ticketing:link_previews:#{ticket_id}" }, duration: 5.minutes

      # Queued at every save whose description holds a link without a fresh preview: an expired card
      # is read again even when the save changed other fields. Nothing is queued when all are fresh.
      def self.enqueue_for(ticket)
        urls = Links.from(ticket.description)
        return if urls.empty?

        fresh = Ticketing::LinkPreview.where(organization_id: ticket.project.organization_id, url: urls)
                                      .where(expires_at: Time.current..).count
        perform_later(ticket_id: ticket.id) if fresh < urls.size
      end

      def perform(ticket_id:)
        ticket = Ticketing::Ticket.includes(project: :organization).find_by(id: ticket_id)
        return if ticket.nil?

        previews = Links.from(ticket.description).map do |url|
          Refresh.call(organization: ticket.project.organization, url:)
        end
        broadcast(ticket) if previews.any? { |preview| preview&.saved_changes? }
      end

      private

      # Same target the page renders (member/tickets/_link_previews_slot), on the stream of the ticket.
      def broadcast(ticket)
        Turbo::StreamsChannel.broadcast_replace_to(
          Realtime::Streams.ticket(ticket),
          target: ActionView::RecordIdentifier.dom_id(ticket, :link_previews),
          partial: "member/tickets/link_previews_slot",
          locals: { ticket:, previews: ForTicket.call(ticket:) }
        )
      end
    end
  end
end
