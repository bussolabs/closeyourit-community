# frozen_string_literal: true

require "net/http"

module Artifacts
  module ProguardMaps
    class Processor < ApplicationService
      MAX_LINES = 500

      def initialize(mapping:, stacktrace:)
        @mapping, @stacktrace = mapping, stacktrace
      end

      def call
        validate_input!
        endpoint = ENV["RETRACE_PROCESSOR_URL"]
        raise Unavailable, "Retrace processing is unavailable" if endpoint.blank?
        uri = URI.parse(endpoint)
        unless %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise Unavailable, "Invalid retrace processor configuration"
        end
        response = request(uri)
        validate_response!(JSON.parse(response, max_nesting: 8))
      rescue JSON::ParserError
        raise Unavailable, "Invalid retrace processor response"
      rescue URI::InvalidURIError, IOError, SystemCallError, Timeout::Error, Net::ProtocolError
        raise Unavailable, "Retrace processing is unavailable"
      end

      private

      def validate_input!
        mapping = @mapping.is_a?(String) ? @mapping.dup.force_encoding(Encoding::UTF_8) : nil
        raise Rejected, "invalid_mapping" unless mapping&.valid_encoding? && mapping.present? && mapping.bytesize <= MAX_MAP && !mapping.include?("\0")
        @mapping = mapping
        raise Rejected, "invalid_stack" unless @stacktrace.is_a?(Array) && @stacktrace.size <= MAX_LINES
        @stacktrace.each do |line|
          raise Rejected, "invalid_stack" unless line.is_a?(String) && line.valid_encoding? && line.bytesize <= 4096 && !line.match?(/[\r\n\x00]/)
        end
      end

      def request(uri)
        body = { mapping: @mapping, stacktrace: @stacktrace }.to_json
        raise Rejected, "request_too_large" if body.bytesize > MAX_REQUEST
        http = Net::HTTP.new(uri.host, uri.port, nil)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 2
        http.read_timeout = http.write_timeout = 12
        request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
        request.body = body
        output = +""
        Timeout.timeout(14, Unavailable, "Retrace processing deadline exceeded") do
          http.request(request) do |response|
            raise Rejected, "retrace_rejected" if %w[400 411 413 415 422].include?(response.code)
            raise Unavailable, "Retrace processing is unavailable" unless response.code == "200"
            response.read_body do |chunk|
              raise Unavailable, "Retrace response exceeds its budget" if output.bytesize + chunk.bytesize > 1.megabyte
              output << chunk
            end
          end
        end
        output
      end

      def validate_response!(value)
        invalid! unless value.is_a?(Hash) && value.keys.sort == %w[groups schema_version] && value["schema_version"].is_a?(Integer) && value["schema_version"] == 1
        groups = value["groups"]
        invalid! unless groups.is_a?(Array) && groups.size == @stacktrace.size
        count = 0
        groups.each_with_index do |group, index|
          count += validate_group!(group, index)
          invalid! if count > 2000
        end
        groups
      end

      def validate_group!(group, index)
        invalid! unless group.is_a?(Hash) && group.keys.sort == %w[alternatives ambiguous index] && group["index"].is_a?(Integer) && group["index"] == index && [ true, false ].include?(group["ambiguous"])
        alternatives = group["alternatives"]
        invalid! unless alternatives.is_a?(Array) && alternatives.size <= 20
        invalid! unless group["ambiguous"] == (alternatives.size > 1)
        alternatives.sum { |alternative| validate_alternative!(alternative) }
      end

      def validate_alternative!(alternative)
        invalid! unless alternative.is_a?(Hash) && alternative.keys == [ "lines" ] && alternative["lines"].is_a?(Array)
        alternative["lines"].each do |line|
          invalid! unless line.is_a?(String) && line.valid_encoding? && line.bytesize <= 16384 && !line.match?(/[\r\n\x00]/)
        end
        alternative["lines"].size
      end

      def invalid!
        raise Unavailable, "Invalid retrace processor response"
      end
    end
  end
end
