# frozen_string_literal: true

module Projects
  module Releases
    # What an SDK asks at start-up: is this version retired, and with which message (CYRA-1161).
    # The answer stays ready for TTL and Retire/Restore drop it, so a retire reaches the next request.
    module Status
      TTL = 5.minutes

      def self.fetch(project:, environment:, version:)
        Rails.cache.fetch(cache_key(project.id, environment, version), expires_in: TTL) do
          release = project.releases.find_by(environment:, version:)
          { retired: release.present? && release.retired?, message: release&.retirement_message }
        end
      end

      def self.expire(release)
        Rails.cache.delete(cache_key(release.project_id, release.environment, release.version))
      end

      def self.cache_key(project_id, environment, version) = [ "release-status", project_id, environment, version ]
      private_class_method :cache_key
    end
  end
end
