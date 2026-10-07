# frozen_string_literal: true

module Instance
  # Asks for the latest community release every few hours and keeps the answer for the update notice
  # (CYRA-1035). Does nothing outside a community install.
  class CheckReleaseJob < ApplicationJob
    queue_as :maintenance

    def perform
      return unless App::SelfHosted.enabled?

      release = ReleaseFeed.call(current: App::Version.tag)
      if release
        Rails.cache.write(Update::CACHE_KEY, release, expires_in: 2.days)
      else
        Rails.cache.delete(Update::CACHE_KEY)
      end
    rescue ReleaseFeed::Error => e
      # The previous answer stays until it expires: a GitHub hiccup must not hide a real release.
      Rails.logger.warn("Instance::CheckReleaseJob could not read the releases: #{e.message}")
    end
  end
end
