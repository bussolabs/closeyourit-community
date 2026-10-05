# frozen_string_literal: true

module Crashes
  class Decode < ApplicationService
    def initialize(header:, bytes:)
      @header = header
      @bytes = bytes.to_s.b
    end

    def call
      raise Rejected, "attachment_too_large" if @bytes.bytesize > MAX_FILE
      filename = @header["filename"].to_s.tr("\\", "/").split("/").last.to_s
      filename = Errors::Ingest::Scrub.call(payload: filename).gsub(/[\x00-\x1f\x7f]/, "").byteslice(0, 200).to_s.scrub
      if @header["attachment_type"] == "event.minidump"
        expanded = Errors::Ingest::EnvelopeParser.gunzip_limited(@bytes, MAX_FILE)
        raise Rejected, "attachment_too_large" if expanded.bytesize > MAX_FILE
        manifest = Processor.call(bytes: expanded)
        { kind: "report", filename: "crash-report.json", bytes: manifest.to_json, manifest: manifest }
      else
        type = @header["attachment_type"]
        raise Rejected, "unsupported_attachment_type" unless type.nil? || type == "event.attachment"
        text = @bytes.dup.force_encoding(Encoding::UTF_8)
        raise Rejected, "unsupported_binary" unless text.valid_encoding? && !text.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/)
        { kind: "text", filename: filename.presence || "attachment.txt", bytes: scrub_text(text) }
      end
    rescue Zlib::Error
      raise Rejected, "invalid_compression"
    end

    private

    def scrub_text(text)
      parsed = JSON.parse(text, max_nesting: 32)
      Errors::Ingest::Scrub.call(payload: parsed).to_json
    rescue JSON::NestingError
      raise Rejected, "attachment_nesting_too_deep"
    rescue JSON::ParserError
      Errors::Ingest::Scrub.call(payload: text)
    end
  end
end
