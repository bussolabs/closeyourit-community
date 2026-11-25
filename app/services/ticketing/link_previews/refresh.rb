# frozen_string_literal: true

module Ticketing
  module LinkPreviews
    # Reads one address for one organization and keeps what its card shows (CYRA-1163). A fresh row is
    # never read again. Page and image go through Seo::Fetch, which refuses internal addresses on every
    # redirect; the image is kept only when it is a whole raster file under the cap.
    class Refresh < ApplicationService
      TIMEOUT = 10
      PAGE_MAX_BYTES = 1_000_000
      IMAGE_MAX_BYTES = 2_000_000
      PAGE_ACCEPT = "text/html,application/xhtml+xml;q=0.9"
      # No SVG: it can carry scripts, and the browser would run them from our own address.
      IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
      IMAGE_ACCEPT = IMAGE_TYPES.join(",")

      def initialize(organization:, url:)
        @organization = organization
        @url = url
      end

      def call
        preview = Ticketing::LinkPreview.find_or_initialize_by(organization: @organization, url: @url)
        return preview if preview.persisted? && preview.fresh?

        page = fetch(@url, max_bytes: PAGE_MAX_BYTES, accept: PAGE_ACCEPT)
        data = ReadPage.call(html: page.body, url: page.final_url) if page.ok? && page.html?
        return record(preview, status: :failed, expires_in: Ticketing::LinkPreview::FAILED_FOR) if data.nil? || data[:title].nil?

        record(preview, status: :ready, expires_in: Ticketing::LinkPreview::READY_FOR,
               image: image(data[:image_url]), **data.slice(:title, :description, :site_name))
      rescue ActiveRecord::RecordNotUnique
        # Another job wrote the same address first: its row is as good as ours.
        Ticketing::LinkPreview.find_by(organization: @organization, url: @url)
      end

      private

      def fetch(url, **options)
        Seo::Fetch.call(url:, timeout: TIMEOUT, budget: TIMEOUT, **options)
      end

      def image(url)
        return nil if url.nil?

        result = fetch(url, max_bytes: IMAGE_MAX_BYTES, accept: IMAGE_ACCEPT, binary: true)
        return nil unless result.ok? && result.body && !result.truncated?

        # The bytes decide the type, not the header the other site sent.
        type = Marcel::MimeType.for(StringIO.new(result.body))
        IMAGE_TYPES.include?(type) ? { bytes: result.body, type: } : nil
      end

      def record(preview, status:, expires_in:, image: nil, title: nil, description: nil, site_name: nil)
        # One save after the attach: a second save would empty the saved_changes the job reads to
        # decide whether the open page needs the new card.
        preview.assign_attributes(status:, title:, description:, site_name:, expires_at: expires_in.from_now)
        if image
          preview.image.attach(io: StringIO.new(image[:bytes]), filename: "preview.#{image[:type].delete_prefix("image/")}",
                               content_type: image[:type], identify: false)
        end
        preview.save!
        preview.image.purge_later if image.nil? && preview.image.attached?
        preview
      end
    end
  end
end
