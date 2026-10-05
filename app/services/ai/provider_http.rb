# frozen_string_literal: true

require "net/http"

module Ai
  # Opens the connection to an AI provider. An address an organization typed is untrusted: it must
  # resolve to a public IP, pinned on the connection so it is not resolved again (NetworkGuard, CYRA-914).
  module ProviderHttp
    class BlockedAddress < StandardError; end

    module_function

    def build(uri, untrusted:, open_timeout:, read_timeout:)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      return http unless untrusted

      address = NetworkGuard.resolved_public_address(uri.host)
      raise BlockedAddress, "AI provider address not allowed: #{uri.host}" if address.nil?

      http.ipaddr = address
      http
    end
  end
end
