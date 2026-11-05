# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Vulnerabilities
  module Registry
    # Asks each ecosystem's public registry when a package version was published (CYRA-1167).
    # Short timeouts: a silent registry must not hold up the vulnerability scan. A version the
    # registry does not know (a private package) gives nil, not an error.
    class Client
      class Error < StandardError
        attr_reader :code

        def initialize(message, code:)
          super(message)
          @code = code
        end
      end

      OPEN_TIMEOUT_SECONDS = 3
      READ_TIMEOUT_SECONDS = 5

      # → Time, or nil when the registry has no date for that version.
      def released_at(ecosystem:, name:, version:)
        case ecosystem
        when Ecosystem::RUBYGEMS
          parse_time(get("https://rubygems.org/api/v2/rubygems/#{escape(name)}/versions/#{escape(version)}.json")&.dig("version_created_at"))
        when Ecosystem::NPM
          parse_time(get("https://registry.npmjs.org/#{name.gsub('/', '%2F')}")&.dig("time", version))
        when Ecosystem::PUB
          parse_time(get("https://pub.dev/api/packages/#{escape(name)}/versions/#{escape(version)}")&.dig("published"))
        when Ecosystem::GO
          parse_time(get("https://proxy.golang.org/#{go_escape(name)}/@v/#{go_escape(go_version(version))}.info")&.dig("Time"))
        end
      end

      private

      def escape(segment) = URI.encode_www_form_component(segment)

      # The Go module proxy spells an upper-case letter as "!" plus the lower-case one.
      def go_escape(path) = path.gsub(/[A-Z]/) { |letter| "!#{letter.downcase}" }

      def go_version(version) = version.start_with?("v") ? version : "v#{version}"

      def parse_time(value)
        value.is_a?(String) ? Time.iso8601(value).utc : nil
      rescue ArgumentError
        nil
      end

      def get(url)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT_SECONDS
        http.read_timeout = READ_TIMEOUT_SECONDS

        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/json"
        handle(http.request(request), uri.host)
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        raise Error.new("#{uri.host} timeout", code: "R502-REG-001")
      rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError
        raise Error.new("#{uri.host} unreachable", code: "R502-REG-001")
      end

      def handle(response, host)
        code = response.code.to_i
        return nil if code == 404
        raise Error.new("#{host} error (#{code})", code: "R502-REG-001") unless code.between?(200, 299)

        data = JSON.parse(response.body.to_s)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        raise Error.new("#{host} invalid response", code: "R502-REG-002")
      end
    end
  end
end
