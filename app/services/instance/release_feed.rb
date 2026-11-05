# frozen_string_literal: true

require "net/http"
require "json"

module Instance
  # The latest community release, when it is newer than the running one, with the changelog entries
  # in between (CYRA-1035). Net::HTTP raw like the other providers of the repo. The stable channel reads
  # only the latest stable release; the beta channel reads the whole list, betas included (CYRA-1160).
  class ReleaseFeed < ApplicationService
    class Error < StandardError; end

    Release = Data.define(:version, :notes)

    CHANNELS = %w[stable beta].freeze
    STABLE_FORMAT = /\A\d+\.\d+\.\d+\z/
    # A beta is X.Y.Z-beta.N and ranks below its stable X.Y.Z, as Gem::Version already orders it.
    VERSION_FORMAT = /\A\d+\.\d+\.\d+(?:-beta\.\d+)?\z/
    LIST_SIZE = 30
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 10

    def self.stable?(version) = version.to_s.match?(STABLE_FORMAT)

    def self.download(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS) do |http|
        http.get(uri.request_uri, "Accept" => "application/json", "User-Agent" => "closeyourit-self-hosted")
      end
      # Net::HTTP hands back bytes: the changelog is Italian, and its accents broke on the page.
      response.body.dup.force_encoding(Encoding::UTF_8).scrub if response.is_a?(Net::HTTPSuccess)
    rescue SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => e
      raise Error, "#{uri.host} unreachable: #{e.class}"
    end

    def initialize(current:, channel: "stable")
      @current = current.to_s.delete_prefix("v")
      @channel = channel.to_s
    end

    def call
      latest = @channel == "beta" ? highest_version : latest_stable_version
      return unless newer?(latest, @current)

      Release.new(version: latest, notes: notes_between(latest))
    end

    private

    def latest_stable_version
      version = tag_version(JSON.parse(list("/releases/latest")))
      # The version ends up in a URL and in the request the host reads: plain digits only, never a beta.
      raise Error, "unexpected release tag #{version.inspect}" unless self.class.stable?(version)

      version
    rescue JSON::ParserError => e
      raise Error, "release list unreadable: #{e.message}"
    end

    # Drafts and tags in any other shape are skipped, not trusted.
    def highest_version
      releases = Array(JSON.parse(list("/releases?per_page=#{LIST_SIZE}"))).grep(Hash).reject { |release| release["draft"] }
      versions = releases.map { |release| tag_version(release) }.grep(VERSION_FORMAT)
      versions.max_by { |version| Gem::Version.new(version) } || raise(Error, "no release in the list")
    rescue JSON::ParserError => e
      raise Error, "release list unreadable: #{e.message}"
    end

    def list(path) = get("#{App::SelfHosted.releases_api}#{path}") || raise(Error, "release list unavailable")

    def tag_version(release) = release["tag_name"].to_s.delete_prefix("v")

    # Entries newer than the running version up to the target; none when the changelog is missing.
    # A beta's own changes still sit under Unreleased at its tag: they become the beta's entry.
    def notes_between(target)
      text = get("#{App::SelfHosted.releases_raw}/v#{target}/CHANGELOG.md")
      return [] unless text

      text = text.sub(/^## \[Unreleased\]/i, "## [#{target}] - beta") unless self.class.stable?(target) || text.include?("## [#{target}]")
      Changelog::Parse.call(text).select { |release| newer?(release.version, @current) && !newer?(release.version, target) }
    end

    def newer?(candidate, base)
      return true unless base.match?(VERSION_FORMAT)

      Gem::Version.new(candidate) > Gem::Version.new(base)
    end

    def get(url) = self.class.download(url)
  end
end
