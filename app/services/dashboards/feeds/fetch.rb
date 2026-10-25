# frozen_string_literal: true

module Dashboards
  module Feeds
    # Reads one service's GET /open-dashboard and keeps the last answer that respects the contract.
    # A failed read never erases the last good report: it records when and why it failed. CYRA-1112
    class Fetch < ApplicationService
      TIMEOUT = 10
      MAX_BYTES = 512.kilobytes
      SCHEMA = JSON.parse(Rails.root.join("contracts/open-dashboard/v1/schema.json").read)
      VALIDATOR = JSONSchemer.schema(
        { "$ref" => "#/$defs/report", "$defs" => SCHEMA.fetch("$defs") },
        regexp_resolver: "ecma", format: true,
        ref_resolver: ->(_) { raise ArgumentError, "External references are disabled" }
      )
      # A broken or hostile service can fail in any of these ways; each must end as a recorded failure.
      NETWORK_ERRORS = [ SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError, Zlib::Error,
                         Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError ].freeze

      def initialize(feed:, now: Time.current)
        @feed = feed
        @now = now
      end

      def call
        report, error = read
        attributes = { checked_at: @now, last_error: error, updated_at: @now }
        attributes.merge!(payload: report, fetched_at: @now) if error.nil?
        # No validation: a read is recorded even if the saved address no longer passes it.
        # Matching the url drops a read of the old service when the address changed meanwhile.
        Feed.where(id: @feed.id, url: @feed.url).update_all(attributes)

        error.nil? ? Result.ok(@feed) : Result.err(AppError.new(error, code: "R502-DASHBOARD-001", status: :bad_gateway))
      end

      private

      def read
        uri = URI.parse(@feed.endpoint)
        address = NetworkGuard.resolved_public_address(uri.host) if uri.scheme == "https"
        return [ nil, "blocked" ] if address.nil?

        response = get(uri, address)
        return [ nil, status_error(response.code) ] unless response.code == "200"

        report = JSON.parse(response.body)
        VALIDATOR.valid?(report) ? [ report, nil ] : [ nil, "invalid_payload" ]
      rescue URI::InvalidURIError
        [ nil, "blocked" ]
      rescue JSON::ParserError
        [ nil, "invalid_payload" ]
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        [ nil, "timeout" ]
      rescue BoundedHttp::ResponseTooLarge
        [ nil, "too_large" ]
      rescue *NETWORK_ERRORS
        [ nil, "unreachable" ]
      end

      def status_error(code)
        case code
        when "401" then "unauthorized"
        when "404" then "not_found"
        else "http_#{code}"
        end
      end

      def get(uri, address)
        http = Net::HTTP.new(uri.host, uri.port)
        http.ipaddr = address # connect to the checked IP; Host, SNI and certificate stay on uri.host
        http.use_ssl = true
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT

        request = Net::HTTP::Get.new(uri.request_uri)
        request["Authorization"] = "Bearer #{@feed.token}"
        request["Accept"] = "application/json"
        BoundedHttp.request(http, request, max_bytes: MAX_BYTES, timeout: TIMEOUT)
      end
    end
  end
end
