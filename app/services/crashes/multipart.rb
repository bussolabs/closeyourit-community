# frozen_string_literal: true

module Crashes
  # Rack's multipart parser operates only on the bounded in-memory body, never disk tempfiles.
  class Multipart < ApplicationService
    def initialize(body:, content_type:)
      @body, @content_type = body, content_type
    end

    def call
      wire = @body.read(MAX_WIRE + 1).to_s.b
      raise Rejected, "request_too_large" if wire.bytesize > MAX_WIRE
      bytes = Errors::Ingest::EnvelopeParser.gunzip_limited(wire, MAX_EXPANDED)
      raise Rejected, "request_too_large" if bytes.bytesize > MAX_EXPANDED
      files = 0
      factory = lambda do |_filename, _type|
        files += 1
        raise Rejected, "too_many_attachments" if files > MAX_FILES
        StringIO.new("".b)
      end
      env = { "rack.input" => StringIO.new(bytes), "CONTENT_TYPE" => @content_type,
              "CONTENT_LENGTH" => bytes.bytesize.to_s, "rack.multipart.tempfile_factory" => factory }
      params = Rack::Multipart.parse_multipart(env)
      raise Rejected, "invalid_multipart" unless params.is_a?(Hash)
      event = metadata(params["sentry"])
      items = params.filter_map do |name, value|
        next unless value.is_a?(Hash) && value[:tempfile].respond_to?(:read)
        value[:tempfile].rewind
        header = { "filename" => value[:filename], "attachment_type" => name == "upload_file_minidump" ? "event.minidump" : "event.attachment" }
        { header: header, bytes: value[:tempfile].read(MAX_FILE + 1) }
      end
      raise Rejected, "duplicate_file_field" unless items.size == files
      raise Rejected, "missing_minidump" unless items.any? { |item| item[:header]["attachment_type"] == "event.minidump" }
      [ event, items ]
    rescue Zlib::Error, JSON::ParserError, EOFError, Rack::Multipart::Error, Rack::QueryParser::ParameterTypeError, Rack::QueryParser::ParamsTooDeepError
      raise Rejected, "invalid_multipart"
    end

    private

    def metadata(value)
      raise Rejected, "invalid_event_metadata" if value.is_a?(String) && value.bytesize > 64.kilobytes
      value = JSON.parse(value, max_nesting: 16) if value.is_a?(String)
      return {} if value.nil?
      raise Rejected, "invalid_event_metadata" unless value.is_a?(Hash)
      # Filenames, arbitrary form fields and user dictionaries never become event context.
      result = value.slice("event_id", "release", "environment", "dist", "platform")
      raise Rejected, "invalid_event_metadata" unless result.values.all? { |item| item.is_a?(String) && item.bytesize <= 1024 && !item.include?("\0") }
      Errors::Ingest::Scrub.call(payload: result)
    end
  end
end
