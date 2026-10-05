# frozen_string_literal: true

require "net/http"

module Crashes
  class Processor < ApplicationService
    def initialize(bytes:)
      @bytes = bytes
    end

    def call
      raise Rejected, "invalid_minidump" unless @bytes.byteslice(0, 4) == "MDMP" && @bytes.bytesize >= 32
      endpoint = ENV["CRASH_PROCESSOR_URL"]
      raise Unavailable, "Crash processing is unavailable" if endpoint.blank?
      uri = URI.parse(endpoint)
      raise Unavailable, "Invalid crash processor configuration" unless %w[http https].include?(uri.scheme) && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 2
      http.read_timeout = 10
      http.write_timeout = 10
      request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/octet-stream")
      request.body = @bytes
      output = +""
      Timeout.timeout(10, Unavailable, "Crash processing deadline exceeded") do
        http.request(request) do |response|
        raise Rejected, "invalid_minidump" if [ "413", "422" ].include?(response.code)
        raise Unavailable, "Crash processing is unavailable" unless response.code == "200"
        response.read_body do |chunk|
          raise Rejected, "report_too_large" if output.bytesize + chunk.bytesize > MAX_REPORT
          output << chunk
        end
      end
      end
      Manifest.call(JSON.parse(output, max_nesting: 16))
    rescue JSON::ParserError
      raise Rejected, "invalid_report"
    rescue URI::InvalidURIError, IOError, SystemCallError, Timeout::Error, Net::ProtocolError
      raise Unavailable, "Crash processing is unavailable"
    end
  end
end
