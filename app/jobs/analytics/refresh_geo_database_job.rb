# frozen_string_literal: true

module Analytics
  # Keeps GeoLite2-Country fresh on the storage volume (CYRA-914 P10). Daily, but it downloads only when
  # the file is missing or older than a week; without MAXMIND_LICENSE_KEY it does nothing.
  class RefreshGeoDatabaseJob < ApplicationJob
    queue_as :batch

    def perform
      result = Analytics::DownloadGeoDatabase.call
      Rails.logger.warn("[geoip] #{result.error.message}") if result.err? && ENV["MAXMIND_LICENSE_KEY"].present?
    end
  end
end
