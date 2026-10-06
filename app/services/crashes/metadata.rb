# frozen_string_literal: true

require "msgpack"

module Crashes
  class Metadata < ApplicationService
    KEYS = %w[event_id release environment dist platform].freeze
    MAX_BYTES = 64.kilobytes

    def initialize(json:, crashpad:)
      @json, @crashpad = json, crashpad
    end

    def call
      raise Rejected, "invalid_event_metadata" if @json && @crashpad
      value = @crashpad ? unpack_crashpad : parse_json
      raise Rejected, "invalid_event_metadata" unless value.is_a?(Hash)
      result = value.slice(*KEYS).transform_values { |item| item.is_a?(String) ? item.dup.force_encoding(Encoding::UTF_8) : item }
      valid = result.values.all? { |item| item.is_a?(String) && item.valid_encoding? && item.bytesize <= 1024 && !item.include?("\0") }
      raise Rejected, "invalid_event_metadata" unless valid
      Errors::Ingest::Scrub.call(payload: result)
    rescue JSON::ParserError, MessagePack::UnpackError, EOFError
      raise Rejected, "invalid_event_metadata"
    end

    private

    def parse_json
      return {} if @json.nil?
      raise Rejected, "invalid_event_metadata" if @json.is_a?(String) && @json.bytesize > MAX_BYTES
      @json.is_a?(String) ? JSON.parse(@json, max_nesting: 16) : @json
    end

    def unpack_crashpad
      raise Rejected, "invalid_event_metadata" unless @crashpad.is_a?(Hash) && @crashpad[:tempfile].respond_to?(:read)
      @crashpad[:tempfile].rewind
      bytes = @crashpad[:tempfile].read(MAX_BYTES + 1).to_s
      raise Rejected, "invalid_event_metadata" if bytes.bytesize > MAX_BYTES
      # A private factory cannot invoke extension callbacks registered by the application.
      unpacker = MessagePack::Factory.new.unpacker
      unpacker.feed(bytes)
      count = unpacker.read_map_header
      raise Rejected, "invalid_event_metadata" if count > 128
      result, seen = {}, {}
      count.times do
        key = unpacker.read
        raise Rejected, "invalid_event_metadata" unless key.is_a?(String) && key.valid_encoding? && key.bytesize <= 256 && !seen[key]
        seen[key] = true
        KEYS.include?(key) ? result[key] = unpacker.read : unpacker.skip
      end
      raise Rejected, "invalid_event_metadata" unless unpacker.buffer.empty?
      result
    end
  end
end
