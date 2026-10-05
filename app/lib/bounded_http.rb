# frozen_string_literal: true

require "timeout"

# Socket read timeouts do not bound a peer that continuously sends small chunks.
module BoundedHttp
  ResponseTooLarge = Class.new(IOError)

  def self.request(http, request, max_bytes:, timeout:)
    Timeout.timeout(timeout) do
      http.request(request) do |response|
        body = +""
        response.read_body do |chunk|
          raise ResponseTooLarge, "HTTP response exceeded its byte limit" if body.bytesize + chunk.bytesize > max_bytes

          body << chunk
        end
        response.body = body
      end
    end
  end
end
