# frozen_string_literal: true

module Ticketing
  module LinkPreviews
    # Retention of link previews (CYRA-1163): a row expired for RETENTION goes, with its image. A link
    # still in a description is read again at its next save; until then it shows as a plain link.
    class PruneJob < ApplicationJob
      queue_as :batch

      RETENTION = 30.days

      def perform
        Ticketing::LinkPreview.where(expires_at: ..RETENTION.ago).find_each(&:destroy!)
      end
    end
  end
end
