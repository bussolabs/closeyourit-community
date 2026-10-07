# frozen_string_literal: true

require "net/http"
require "json"

module Instance
  # The latest community release, when it is newer than the running one, with the changelog entries
  # in between (CYRA-1035). Net::HTTP raw like the other providers of the repo.
  class ReleaseFeed < ApplicationService
    class Error < StandardError; end

    Release = Data.define(:version, :notes)

    VERSION_FORMAT = /\A\d+\.\d+\.\d+\z/
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 10

    def initialize(current:)
      @current = current.to_s.delete_prefix("v")
    end

    def call
      latest = latest_version
      return unless newer?(latest, @current)

      Release.new(version: latest, notes: notes_between(latest))
    end

    private

    def latest_version
      body = get("#{App::SelfHosted.releases_api}/releases/latest") || raise(Error, "release list unavailable")
      version = JSON.parse(body)["tag_name"].to_s.delete_prefix("v")
      # The version ends up in a URL and in the request the host reads: plain digits only.
      raise Error, "unexpected release tag #{version.inspect}" unless version.match?(VERSION_FORMAT)

      version
    rescue JSON::ParserError => e
      raise Error, "release list unreadable: #{e.message}"
    end

    # Entries newer than the running version up to the target; none when the changelog is missing.
    def notes_between(target)
      text = get("#{App::SelfHosted.releases_raw}/v#{target}/CHANGELOG.md")
      return [] unless text

      Changelog::Parse.call(text).select { |release| newer?(release.version, @current) && !newer?(release.version, target) }
    end

    def newer?(candidate, base)
      return true unless base.match?(VERSION_FORMAT)

      Gem::Version.new(candidate) > Gem::Version.new(base)
    end

    def get(url)
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
  end
end
