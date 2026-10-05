# frozen_string_literal: true

require "stringio"
require "zlib"

module Replays
  # Ricostruisce lo stream rrweb di una sessione per il player nel Monitor: scarica i chunk gzip
  # nell'ordine dei seq e concatena gli eventi. È I/O sui blob (ActiveStorage) → sta nel path di
  # LETTURA della UI, mai in quello di ingest. Un chunk corrotto viene saltato (best-effort).
  class Read < ApplicationService
    def initialize(session:)
      @session = session
    end

    def call
      @remaining_bytes = Constants::SESSION_MAX_DECOMPRESSED_BYTES
      attachments = ordered_attachments
      if attachments.size > Constants::SESSION_MAX_CHUNKS ||
         attachments.sum { |attachment| attachment.blob.byte_size } > Constants::SESSION_MAX_COMPRESSED_BYTES
        raise Replays::LimitExceeded
      end

      events = []
      attachments.each do |attachment|
        batch = decode(attachment)
        raise Replays::LimitExceeded if events.size + batch.size > Constants::SESSION_MAX_EVENTS

        events.concat(batch)
      end
      Result.ok(events)
    rescue Replays::LimitExceeded
      Result.err(AppError.new("Replay session exceeds the playback budget", code: "R413-REPLAY-003", status: :content_too_large))
    end

    private

    # Ordina per il seq incorporato nel filename ("<sid>-<seq>.json.gz"): l'ordine di attach non è
    # garantito monotòno, il seq del client sì.
    def ordered_attachments
      @session.chunks.includes(:blob).limit(Constants::SESSION_MAX_CHUNKS + 1)
        .sort_by { |attachment| seq_of(attachment.blob.filename.to_s) }
    end

    def seq_of(filename)
      filename[/-(\d+)\.json\.gz\z/, 1].to_i
    end

    def decode(attachment)
      raw = +"".b
      attachment.blob.download do |chunk|
        raise Replays::LimitExceeded if raw.bytesize + chunk.bytesize > Constants::CHUNK_MAX_COMPRESSED_BYTES

        raw << chunk
      end
      limit = [ @remaining_bytes, Constants::CHUNK_MAX_DECOMPRESSED_BYTES ].min
      decoded = Zlib::GzipReader.wrap(StringIO.new(raw)) { |reader| reader.read(limit + 1) }
      raise Replays::LimitExceeded if decoded.bytesize > limit

      @remaining_bytes -= decoded.bytesize
      events = JSON.parse(decoded)
      events.is_a?(Array) ? events : []
    rescue Zlib::Error, JSON::ParserError
      []
    end
  end
end
