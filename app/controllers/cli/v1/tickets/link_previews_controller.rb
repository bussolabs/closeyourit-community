# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # CYRA-1163 — the image of a link card, for the clients that read the ticket detail. Baseline of
      # whoever sees the ticket, like the attachment download: the preview must belong to a link the
      # ticket still holds, so an id of another ticket or organization is a 404.
      class LinkPreviewsController < Cli::V1::BaseController
        before_action :set_project!

        def image
          ticket = find_ticket!(@project, params[:ticket_id])
          preview = ::Ticketing::LinkPreviews::ForTicket.call(ticket:).find { |row| row.id == params[:id] }
          raise ActiveRecord::RecordNotFound if preview.nil? || !preview.image.attached?

          blob = preview.image.blob
          response.headers["X-Content-Type-Options"] = "nosniff"
          send_data blob.download, filename: blob.filename.sanitized, type: blob.content_type, disposition: "inline"
        end
      end
    end
  end
end
