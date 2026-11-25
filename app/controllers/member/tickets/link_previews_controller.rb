# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-1163 — the image of a link card, served by us so the reader's browser never calls the other
    # site. Like the ticket files (CYRA-1121), every request checks again that the account sees the
    # ticket and that the preview belongs to a link the ticket still holds; the generic storage routes
    # answer 404 for these images (RestrictedBlobServing).
    class LinkPreviewsController < Member::BaseController
      permission_not_required "The image of a link card is baseline for whoever sees the ticket: the " \
                              "boundary is visibility, checked again on every request.",
                              only: %i[image]

      # An image is not a page opened.
      skip_after_action :record_usage

      def image
        ticket = visible.tickets.find(params[:ticket_id])
        preview = ::Ticketing::LinkPreviews::ForTicket.call(ticket:).find { |row| row.id == params[:id] }
        raise ActiveRecord::RecordNotFound if preview.nil? || !preview.image.attached?

        blob = preview.image.blob
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.strong_etag = blob.checksum || blob.key
        response.cache_control.merge!(no_cache: true, extras: [ "private" ])
        return head(:not_modified) if request.fresh?(response)

        send_data blob.download, filename: blob.filename.sanitized, type: blob.content_type, disposition: "inline"
      rescue ActiveStorage::FileNotFoundError
        head :not_found
      end
    end
  end
end
