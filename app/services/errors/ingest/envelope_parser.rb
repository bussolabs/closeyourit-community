# frozen_string_literal: true

require "stringio"
require "zlib"

module Errors
  module Ingest
    # Parse bounded Sentry envelopes completely before admission. Events keep the legacy return
    # value; validated session items are exposed separately for synchronous persistence.
    class EnvelopeParser < ApplicationService
      MultipleEvents = Class.new(StandardError)
      SessionLimitExceeded = Class.new(StandardError)
      ItemLimitExceeded = Class.new(StandardError)
      MAX_ITEMS = 100
      MAX_EVENTS = 50
      MAX_COMPRESSED = 1.megabyte
      MAX_DECOMPRESSED = 5.megabytes
      IGNORED_TYPES = %w[transaction client_report profile replay_event
                         replay_recording check_in feedback span log metric].freeze
      attr_reader :ignored_counts, :dsn, :session_items, :attachments, :event_id

      GZIP_MAGIC = "\x1f\x8b".b

      # Decomprime `bytes` se gzip (sniff magic bytes), leggendo AL PIÙ max+1 byte: contro una
      # gzip-bomb (KB compressi → GB decompressi) alloca max+1 byte invece dell'intero stream, così
      # il check `> max` a valle scatta senza esaurire la RAM. Se non gzip, restituisce i byte grezzi.
      # Unico punto di verità condiviso con Api::IngestController#parse_json (endpoint legacy /store).
      def self.gunzip_limited(bytes, max)
        bytes = bytes.to_s.b
        return bytes unless bytes.byteslice(0, 2) == GZIP_MAGIC

        Zlib::GzipReader.new(StringIO.new(bytes)).read(max + 1).to_s
      end

      def initialize(body:)
        @body = (body.respond_to?(:read) ? body.read(MAX_COMPRESSED + 1) : body).to_s.b
        @ignored_counts = Hash.new(0)
        @session_items = []
        @attachments = []
      end

      def call
        return too_large if @body.bytesize > MAX_COMPRESSED

        data = maybe_gunzip(@body)
        return too_large if data.bytesize > MAX_DECOMPRESSED

        Result.ok(parse_events(data))
      rescue SessionLimitExceeded
        too_large
      rescue ItemLimitExceeded
        too_large
      rescue MultipleEvents
        Result.err(AppError.new("Multiple events cannot share an envelope event identifier", code: "R422-INGEST-001", status: :unprocessable_content))
      rescue JSON::ParserError, Zlib::Error, ArgumentError
        Result.err(AppError.new("Malformed envelope", code: "R422-INGEST-001", status: :unprocessable_content))
      end

      private

      def too_large
        Result.err(AppError.new("Payload too large", code: "R413-INGEST-001", status: :content_too_large))
      end

      def maybe_gunzip(bytes)
        self.class.gunzip_limited(bytes, MAX_DECOMPRESSED)
      end

      # Header envelope (1ª riga) poi, per ogni item: header JSON con "type"/"length" opzionale +
      # payload (length byte se indicato, altrimenti fino a newline). Tiene solo gli item "event".
      def parse_events(data)
        io = StringIO.new(data)
        envelope = read_envelope_header(io)

        events = []
        item_count = 0
        until io.eof?
          header_line = io.gets
          next if header_line.blank?
          item_count += 1
          raise ItemLimitExceeded if item_count > MAX_ITEMS

          header = JSON.parse(header_line)
          raise ArgumentError unless header.is_a?(Hash) && header["type"].is_a?(String)

          payload = read_item_payload(io, header)
          if header["type"] == "event"
            append_event(events, payload, envelope)
          elsif header["type"] == "attachment"
            @attachments << { header: header, bytes: payload.to_s.b }
          elsif %w[session sessions].include?(header["type"])
            decoded = ::SessionHealth::Ingest::Decode.call(type: header["type"], payload: JSON.parse(payload.to_s))
            decoded.each { |value| @session_items << { type: header["type"], value: value } }
            raise SessionLimitExceeded if @session_items.size > ::SessionHealth::Ingest::Decode::MAX_GROUPS
          else
            type = IGNORED_TYPES.include?(header["type"]) ? header["type"] : "unknown"
            @ignored_counts[type] += 1
          end
        end
        events
      end

      def append_event(events, payload, envelope)
        raise ArgumentError if payload.blank?
        event = JSON.parse(payload)
        raise ArgumentError unless EventPayload.valid?(event)

        event["event_id"] = envelope["event_id"] if envelope["event_id"].present?
        events << event
        raise ItemLimitExceeded if events.size > MAX_EVENTS
        raise MultipleEvents if envelope["event_id"].present? && events.size > 1
      end

      def read_envelope_header(io)
        envelope = JSON.parse(io.gets || "")
        raise ArgumentError unless envelope.is_a?(Hash)
        raise ArgumentError if envelope.key?("event_id") && !envelope["event_id"].is_a?(String)

        @event_id = envelope["event_id"]
        @dsn = envelope["dsn"]
        raise ArgumentError unless @dsn.nil? || @dsn.is_a?(String)

        envelope
      end

      def read_item_payload(io, header)
        return io.gets&.delete_suffix("\n") unless header.key?("length")

        length = header["length"]
        raise ArgumentError unless length.is_a?(Integer) && length >= 0 && length <= MAX_DECOMPRESSED

        body = io.read(length)
        raise ArgumentError unless body && body.bytesize == length
        raise ArgumentError unless io.eof? || io.read(1) == "\n"

        body
      end
    end
  end
end
