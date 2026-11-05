# frozen_string_literal: true

module Instance
  # Asks for the latest community release of the chosen channel every few hours and keeps the answer
  # for the update notice (CYRA-1035), then fetches the signed list of insecure versions (CYRA-1160).
  # Does nothing outside a community install.
  class CheckReleaseJob < ApplicationJob
    queue_as :maintenance

    def perform
      return unless App::SelfHosted.enabled?

      check_release
      check_advisories
    end

    private

    def check_release
      release = ReleaseFeed.call(current: App::Version.tag, channel: Settings::Global.instance.release_channel)
      if release
        Rails.cache.write(Update::CACHE_KEY, release, expires_in: 2.days)
      else
        Rails.cache.delete(Update::CACHE_KEY)
      end
    rescue ReleaseFeed::Error => e
      # The previous answer stays until it expires: a GitHub hiccup must not hide a real release.
      Rails.logger.warn("Instance::CheckReleaseJob could not read the releases: #{e.message}")
    end

    # A missing, forged or older list is dropped and the stored one keeps deciding: it never expires.
    def check_advisories
      body = ReleaseFeed.download(App::SelfHosted.advisories_url) || raise(Advisories::Invalid, "security list unavailable")
      list = Advisories.verify(body)
      return if Settings::Global.instance.store_security_advisories(list)

      Rails.logger.info("Instance::CheckReleaseJob kept the stored security list: the one received is not newer")
    rescue ReleaseFeed::Error, Advisories::Invalid => e
      Rails.logger.warn("Instance::CheckReleaseJob kept the stored security list: #{e.message}")
    end
  end
end
