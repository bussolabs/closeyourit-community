# frozen_string_literal: true

require "net/http"
require "json"

module Agents
  module SkillReleases
    # Published releases of the public cyi skills package (CYRA-912). `entries` are the releases that can
    # be recorded: vX.Y.Z tag, the cyi-X.Y.Z.tgz asset and a `sha256: <hex>` line written by the release
    # CI. `listed` is every version GitHub still shows as published, readable or not: a version missing
    # from it was withdrawn upstream. Net::HTTP raw like Instance::ReleaseFeed.
    class Feed < ApplicationService
      class Error < StandardError; end

      Entry = Data.define(:version, :url, :sha256, :git_sha, :published_at)
      Listing = Data.define(:entries, :listed)

      TAG_FORMAT = /\Av(\d+\.\d+\.\d+)\z/
      SHA256_LINE = /^sha256:\s*([0-9a-fA-F]{64})\s*$/
      OPEN_TIMEOUT_SECONDS = 5
      READ_TIMEOUT_SECONDS = 10
      PER_PAGE = 100
      MAX_PAGES = 10

      def call
        all = releases
        Listing.new(entries: all.filter_map { |release| safe_entry(release) },
                    listed: all.filter_map { |release| listed_version(release) }.to_set)
      end

      private

      # Every page: a version on page two must not look withdrawn just because it was not read.
      def releases
        (1..MAX_PAGES).each_with_object([]) do |page, all|
          list = release_page(page)
          all.concat(list)
          break all if list.size < PER_PAGE
        end
      end

      def release_page(page)
        list = JSON.parse(get("#{App::SkillsCatalog.releases_api}/releases?per_page=#{PER_PAGE}&page=#{page}"))
        raise Error, "release list is not a list" unless list.is_a?(Array)

        list
      rescue JSON::ParserError => e
        raise Error, "release list unreadable: #{e.message}"
      end

      def listed_version(release)
        return unless release.is_a?(Hash)
        return if release["draft"] || release["prerelease"]

        release["tag_name"].to_s[TAG_FORMAT, 1]
      end

      # One odd release must not hide the good ones: a malformed item is logged and skipped.
      def safe_entry(release)
        entry(release)
      rescue TypeError, NoMethodError, ArgumentError => e
        Rails.logger.warn("[Agents::SkillReleases::Feed] release skipped: #{e.class}")
        nil
      end

      def entry(release)
        return if release["draft"] || release["prerelease"]

        version = release["tag_name"].to_s[TAG_FORMAT, 1] or return
        asset = Array(release["assets"]).find { |a| a["name"] == "cyi-#{version}.tgz" }
        sha256 = release["body"].to_s[SHA256_LINE, 1]
        unless asset && sha256
          Rails.logger.warn("[Agents::SkillReleases::Feed] v#{version} skipped: missing package or sha256 line")
          return
        end

        url = asset["browser_download_url"].to_s
        published_at = Time.zone.parse(release["published_at"].to_s)
        unless published_at && url.start_with?("https://")
          Rails.logger.warn("[Agents::SkillReleases::Feed] v#{version} skipped: missing published_at or non-https package url")
          return
        end

        Entry.new(version:, url:, sha256: sha256.downcase,
                  git_sha: release["target_commitish"].to_s[/\A[0-9a-f]{40}\z/], published_at:)
      end

      def get(url)
        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS) do |http|
          http.get(uri.request_uri, "Accept" => "application/vnd.github+json", "User-Agent" => "closeyourit-skills")
        end
        raise Error, "#{uri.host} answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response.body
      rescue SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, EOFError, IOError,
             Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error => e
        raise Error, "#{uri.host} unreachable: #{e.class}"
      end
    end
  end
end
