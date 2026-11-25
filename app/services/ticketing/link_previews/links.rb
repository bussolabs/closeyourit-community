# frozen_string_literal: true

module Ticketing
  module LinkPreviews
    # The web addresses written in a ticket description, in order and without repeats, at most MAX
    # (CYRA-1163). Only http and https with a host: anything else never becomes a visit.
    module Links
      MAX = 5
      URL = %r{https?://[^\s<>"'`()\[\]\{\}|\\^]+}i
      # Punctuation that closes a sentence or a markdown mark, not the address.
      TRAILING = /[.,;:!?*_~]+\z/

      module_function

      def from(text)
        text.to_s.scan(URL).filter_map { |raw| normalize(raw.sub(TRAILING, "")) }.uniq.first(MAX)
      end

      def normalize(raw)
        return nil if raw.length > Ticketing::LinkPreview::MAX_URL_LENGTH

        uri = URI.parse(raw)
        uri.is_a?(URI::HTTP) && uri.host.present? ? uri.to_s : nil
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
