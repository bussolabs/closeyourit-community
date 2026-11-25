# frozen_string_literal: true

module Ticketing
  module LinkPreviews
    # From a page's served HTML to what its card shows: title, short description, site and the image
    # address, from the Open Graph tags first and the page's own tags after (CYRA-1163).
    # A title equal to the site name is no title: a private file often answers only with the site's name.
    class ReadPage < ApplicationService
      TITLE_LENGTH = 200
      DESCRIPTION_LENGTH = 300
      SITE_LENGTH = 100

      def initialize(html:, url:)
        @html = html.to_s
        @url = url.to_s
      end

      def call
        document = Nokogiri::HTML5(@html)
        site = clip(meta(document, "og:site_name"), SITE_LENGTH) || host
        title = clip(meta(document, "og:title") || meta(document, "twitter:title") ||
                     document.at_css("head > title")&.text, TITLE_LENGTH)
        title = nil if title&.casecmp?(site.to_s)

        { title:, site_name: site,
          description: clip(meta(document, "og:description") || meta(document, "description"), DESCRIPTION_LENGTH),
          image_url: absolute(meta(document, "og:image:secure_url") || meta(document, "og:image") ||
                              meta(document, "twitter:image")) }
      end

      private

      # Open Graph uses `property`, Twitter and plain tags `name`; the value is matched case-insensitively.
      def meta(document, key)
        node = document.css("meta").find do |tag|
          [ tag["property"], tag["name"] ].any? { |value| value.to_s.strip.casecmp?(key) }
        end
        node && node["content"].to_s.squish.presence
      end

      def clip(text, length)
        text.to_s.squish.presence&.truncate(length)
      end

      def host
        URI.parse(@url).host.to_s.delete_prefix("www.").presence
      rescue URI::InvalidURIError
        nil
      end

      def absolute(address)
        return nil if address.blank?

        Links.normalize(URI.join(@url, address).to_s)
      rescue URI::Error
        nil
      end
    end
  end
end
