# frozen_string_literal: true

module Artifacts
  module ProguardMaps
    module Identity
      module_function

      def call(metadata:)
        release = SourceMaps::Identity.text(metadata["release"], 255)
        raise Rejected, "missing_release" if release.blank?
        dist = metadata["dist"].nil? ? nil : SourceMaps::Identity.text(metadata["dist"], 255).presence
        [ release, dist ].compact.each do |value|
          raise Rejected, "unsafe_build_identity" unless Errors::Ingest::Scrub.call(payload: value) == value
        end
        { release: release, dist: dist, debug_id: SourceMaps::Identity.debug_id(metadata["debug_id"]) }
      end
    end
  end
end
