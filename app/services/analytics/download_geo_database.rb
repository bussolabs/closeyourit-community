# frozen_string_literal: true

require "net/http"
require "rubygems/package"
require "zlib"

module Analytics
  # Downloads GeoLite2-Country into GEOIP_DB_PATH when it is missing or older than a week (CYRA-914 P10).
  # Without MAXMIND_LICENSE_KEY it does nothing: the country lookup keeps degrading to nil as before.
  # The new file replaces the old one by rename, so a failed download leaves the old one in place.
  class DownloadGeoDatabase < ApplicationService
    URL = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=%<key>s&suffix=tar.gz"
    MAX_AGE = 7.days
    MAX_REDIRECTS = 3
    TIMEOUT_SECONDS = 30

    def initialize(license_key: ENV["MAXMIND_LICENSE_KEY"], path: Analytics::Constants::GEOIP_DB_PATH)
      @license_key = license_key
      @path = path
    end

    def call
      return Result.err(AppError.new("MAXMIND_LICENSE_KEY not set", code: "R503-GEO-001", status: :service_unavailable)) if @license_key.blank?
      return Result.ok(:fresh) if File.exist?(@path) && File.mtime(@path) > MAX_AGE.ago

      database = extract(fetch(URI(format(URL, key: ERB::Util.url_encode(@license_key)))))
      write(database)
      Result.ok(:downloaded)
    rescue StandardError => e
      # The message never carries the key: MaxMind puts it only in the URL, which is not logged.
      Result.err(AppError.new("GeoLite2 download failed: #{e.class.name}", code: "R502-GEO-001", status: :bad_gateway))
    end

    private

    def fetch(uri, redirects = MAX_REDIRECTS)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT_SECONDS,
                                                     read_timeout: TIMEOUT_SECONDS) { |http| http.get(uri.request_uri) }
      case response
      when Net::HTTPSuccess then response.body
      when Net::HTTPRedirection
        raise "too many redirects" if redirects.zero?

        fetch(URI(response["location"]), redirects - 1)
      else raise "HTTP #{response.code}"
      end
    end

    def extract(archive)
      Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(archive))) do |tar|
        entry = tar.find { |file| file.file? && File.basename(file.full_name) == "GeoLite2-Country.mmdb" }
        raise "no GeoLite2-Country.mmdb in the archive" if entry.nil?

        return entry.read
      end
    end

    def write(database)
      FileUtils.mkdir_p(File.dirname(@path))
      temporary = "#{@path}.download"
      File.binwrite(temporary, database)
      File.rename(temporary, @path)
    end
  end
end
