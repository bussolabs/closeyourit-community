# frozen_string_literal: true

require "maxmind/db"

module Analytics
  # Geolocalizzazione country (ISO alpha-2) da IP, offline, via GeoLite2-Country (.mmdb). Va chiamata
  # INLINE nel controller ingest — accanto ad Analytics::Anonymize — così l'IP produce solo il
  # country_code e poi muore (mai persistito, mai passato ai job). Degrado SEMPRE silenzioso: DB
  # assente (dev/test), IP privato/non risolto, IP malformato o DB corrotto → nil, l'ingest non
  # fallisce mai per la geo.
  class Geo
    def self.country_code(ip, reader: default_reader)
      return nil if ip.blank? || reader.nil?

      record = reader.get(ip)
      record&.dig("country", "iso_code")
    rescue StandardError
      nil
    end

    # The file is downloaded and replaced while the app runs (Analytics::RefreshGeoDatabaseJob): its
    # modification time is looked at no more than once a minute, and a new file is opened (CYRA-914 P10).
    RECHECK_EVERY = 1.minute

    # Reader memoized from the file on disk (MODE_MEMORY: the Country DB is small and loaded in RAM).
    def self.default_reader
      return @default_reader if defined?(@checked_at) && @checked_at > RECHECK_EVERY.ago

      @checked_at = Time.current
      path = Analytics::Constants::GEOIP_DB_PATH
      mtime = File.exist?(path) ? File.mtime(path) : nil
      return @default_reader if defined?(@mtime) && mtime == @mtime

      @mtime = mtime
      @default_reader = mtime ? MaxMind::DB.new(path, mode: MaxMind::DB::MODE_MEMORY) : nil
    rescue StandardError
      @default_reader = nil
    end

    def self.reset_reader!
      remove_instance_variable(:@checked_at) if defined?(@checked_at)
      remove_instance_variable(:@mtime) if defined?(@mtime)
      @default_reader = nil
    end
  end
end
