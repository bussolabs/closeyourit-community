# frozen_string_literal: true

module Artifacts
  module SourceMaps
    module Identity
      module_function

      def call(metadata:, map:)
        release = text(metadata["release"], 255)
        raise Rejected, "missing_release" if release.blank?
        dist = metadata["dist"].nil? ? nil : text(metadata["dist"], 255).presence
        [ release, dist ].compact.each do |value|
          raise Rejected, "unsafe_build_identity" unless Errors::Ingest::Scrub.call(payload: value) == value
        end
        ids = [ metadata["debug_id"], map["debug_id"], map["debugId"] ].compact.map { |value| debug_id(value) }.uniq
        raise Rejected, "debug_identity_conflict" if ids.size > 1
        { release: release, dist: dist, generated_file: generated_file(metadata["generated_file"]), debug_id: ids.first }
      end

      def generated_file(value)
        value = text(value, 4096)
        raise Rejected, "missing_generated_file" if value.blank?
        uri = URI.parse(value)
        raise Rejected, "generated_file_userinfo" if uri.userinfo
        uri.query = uri.fragment = nil
        canonical = uri.to_s
        # Match the same scrubbed path retained on error frames; never guess a basename.
        cleaned = Errors::Ingest::Scrub.call(payload: canonical)
        raise Rejected, "unsafe_generated_file" unless cleaned == canonical
        canonical
      rescue URI::InvalidURIError, URI::InvalidComponentError
        raise Rejected, "invalid_generated_file"
      end

      def debug_id(value)
        value = text(value, 36).downcase
        raw = value.delete("-")
        raise Rejected, "invalid_debug_id" unless raw.match?(/\A[0-9a-f]{32}\z/) && !raw.match?(/\A0+\z/) && [ 32, 36 ].include?(value.size)
        canonical = [ raw[0, 8], raw[8, 4], raw[12, 4], raw[16, 4], raw[20, 12] ].join("-")
        raise Rejected, "invalid_debug_id" unless value == raw || value == canonical
        canonical
      end

      def text(value, limit)
        raise Rejected, "invalid_identity" unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= limit && !value.match?(/[\x00-\x1f\x7f]/)
        value
      end
    end
  end
end
