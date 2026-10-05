# frozen_string_literal: true

require "net/http"
require "base64"

module Artifacts
  module NativeSymbols
    class Processor < ApplicationService
      MAX_BINARY = 20.megabytes
      MAX_REQUEST = 28.megabytes
      MAX_RESPONSE = 1.megabyte
      OBJECT_KEYS = %w[architecture code_id debug_id format has_debug_info has_symbols preferred_load_address usable].freeze
      LOCATION_KEYS = %w[file function function_address line symbol].freeze

      def initialize(bytes:, expected:, addresses:)
        @bytes, @expected, @addresses = bytes, expected.stringify_keys, addresses
      end

      def call
        validate_input!
        endpoint = ENV["NATIVE_SYMBOL_PROCESSOR_URL"]
        raise Unavailable, "Native processing is unavailable" if endpoint.blank?
        uri = URI.parse(endpoint)
        unless %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise Unavailable, "Invalid native processor configuration"
        end
        validate_response(JSON.parse(request(uri), max_nesting: 12))
      rescue JSON::ParserError, URI::InvalidURIError, IOError, SystemCallError, Timeout::Error, Net::ProtocolError
        raise Unavailable, "Native processing is unavailable"
      end

      private

      def validate_input!
        raise Rejected, "invalid_native_object" unless @bytes.is_a?(String) && @bytes.bytesize.between?(1, MAX_BINARY)
        raise Rejected, "invalid_native_addresses" unless @addresses.is_a?(Array) && @addresses.size <= 500 && @addresses.all? { |address| address.is_a?(String) && address.match?(/\A0x[0-9a-f]{1,8}\z/) && address.to_i(16) < 0xffffffff }
      end

      def request(uri)
        body = { object_base64: Base64.strict_encode64(@bytes), expected: @expected.compact, addresses: @addresses }.to_json
        raise Rejected, "request_too_large" if body.bytesize > MAX_REQUEST
        http = Net::HTTP.new(uri.host, uri.port, nil)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 2
        http.read_timeout = http.write_timeout = 12
        message = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
        message.body = body
        output = +""
        Timeout.timeout(14, Unavailable, "Native processing deadline exceeded") do
          http.request(message) do |response|
            raise Rejected, "native_processing_rejected" if %w[400 411 413 415 422].include?(response.code)
            raise Unavailable, "Native processing is unavailable" unless response.code == "200"
            response.read_body do |chunk|
              invalid! if output.bytesize + chunk.bytesize > MAX_RESPONSE
              output << chunk
            end
          end
        end
        output
      end

      def validate_response(value)
        invalid! unless value.is_a?(Hash) && value.keys.sort == %w[frames objects schema_version selected] && value["schema_version"].is_a?(Integer) && value["schema_version"] == 1
        objects = value["objects"]
        selected = value["selected"]
        invalid! unless objects.is_a?(Array) && objects.size.between?(1, 16) && selected.is_a?(Integer) && selected.between?(0, objects.size - 1)
        objects.each { |object| validate_object!(object) }
        object = objects.fetch(selected)
        invalid! unless matches_identity?(object)
        frames = value["frames"]
        invalid! unless frames.is_a?(Array) && frames.size == @addresses.size
        frames.each_with_index { |frame, index| validate_frame!(frame, index) }
        value
      end

      def matches_identity?(object)
        object["usable"] && @expected.compact.all? { |key, wanted| object[key] == wanted }
      end

      def validate_object!(object)
        invalid! unless object.is_a?(Hash) && object.keys.sort == OBJECT_KEYS
        invalid! unless %w[usable has_debug_info has_symbols].all? { |key| [ true, false ].include?(object[key]) }
        invalid! unless %w[format architecture debug_id].all? { |key| string?(object[key]) }
        invalid! unless object["code_id"].nil? || string?(object["code_id"])
        invalid! unless hex?(object["preferred_load_address"])
      end

      def validate_frame!(frame, index)
        invalid! unless frame.is_a?(Hash) && frame.keys.sort == %w[address index locations status] && frame["index"].is_a?(Integer) && frame["index"] == index && frame["address"] == @addresses[index]
        locations = frame["locations"]
        invalid! unless locations.is_a?(Array) && locations.size <= 32 && %w[resolved unresolved].include?(frame["status"])
        invalid! unless (frame["status"] == "resolved") == locations.any?
        locations.each { |location| validate_location!(location) }
      end

      def validate_location!(location)
        invalid! unless location.is_a?(Hash) && location.keys.sort == LOCATION_KEYS
        invalid! unless %w[file function symbol].all? { |key| location[key].nil? || string?(location[key]) }
        invalid! unless location["line"].nil? || (location["line"].is_a?(Integer) && location["line"].between?(0, 0xffffffff))
        invalid! unless location["function_address"].nil? || hex?(location["function_address"])
      end

      def string?(value) = value.is_a?(String) && value.valid_encoding? && value.bytesize <= 4096 && !value.include?("\0")
      def hex?(value) = value.is_a?(String) && value.match?(/\A0x[0-9a-f]+\z/) && value.to_i(16) <= 2**64 - 1

      def invalid!
        raise Unavailable, "Invalid native processor response"
      end
    end
  end
end
