# frozen_string_literal: true

module Ticketing
  module LinkPreviews
    # The cards a ticket shows: the ready previews of the links its description holds now, in the
    # order they are written (CYRA-1163). Same organization only, so the lookup is also the access
    # check of the image routes: a preview not reachable from a ticket the reader sees is not found.
    class ForTicket < ApplicationService
      def initialize(ticket:)
        @ticket = ticket
      end

      def call
        urls = Links.from(@ticket.description)
        return [] if urls.empty?

        Ticketing::LinkPreview.ready.with_attached_image
                              .where(organization_id: @ticket.project.organization_id, url: urls)
                              .select(&:card?)
                              .sort_by { |preview| urls.index(preview.url) }
      end
    end
  end
end
