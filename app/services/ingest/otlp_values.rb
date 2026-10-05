# frozen_string_literal: true

require "base64"

module Ingest
  module OtlpValues
    class Malformed < StandardError; end
    class Rejected < StandardError; end
    UINT64 = (2**64) - 1
    PRIVATE_KEY = /password|passwd|secret|token|authorization|cookie|api[._-]?key|email|phone|user[._-]?(id|name)|client[._-]?address|db[._-]?(statement|query)|sql/i

    private

    def object(value)
      raise Malformed, "Expected an object" unless value.is_a?(Hash)
      value
    end

    def array(value)
      return [] if value.nil?
      raise Malformed, "Expected an array" unless value.is_a?(Array)
      value
    end

    def text(value, default: "")
      return default if value.nil?
      raise Rejected, "Invalid string" unless value.is_a?(String) && value.valid_encoding? && !value.include?("\u0000")
      Errors::Ingest::Scrub.call(payload: value)
    end

    def integer(value, max: UINT64, min: 0)
      value = value.to_i if value.is_a?(String) && value.match?(/\A-?\d+\z/)
      raise Rejected, "Invalid integer" unless value.is_a?(Integer) && value.between?(min, max)
      value
    end

    def identifier(value, length:, empty: false)
      return nil if empty && (value.nil? || value == "")
      raise Rejected, "Invalid identifier" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{#{length}}\z/i) && value != "0" * length
      value.downcase
    end

    def attributes(value, depth: 0)
      list = array(value)
      raise Rejected, "Attribute budget exceeded" if list.size > 128 || depth > 8 || JSON.generate(list).bytesize > 65_536
      seen = {}
      sanitized_keys = {}
      list.map do |entry|
        object(entry)
        key = entry["key"]
        raise Rejected, "Invalid attribute key" unless key.is_a?(String) && key.valid_encoding? && !key.include?("\u0000") && key.bytesize <= 256 && !seen[key]
        seen[key] = true
        clean_key = text(key)
        raise Rejected, "Sanitized attribute keys collide" if sanitized_keys[clean_key]
        sanitized_keys[clean_key] = true
        decoded = any_value(entry["value"], depth: depth)
        { "key" => clean_key, "value" => sensitive_attribute?(key) ? { "stringValue" => "[FILTERED]" } : decoded }
      end.sort_by { |entry| entry["key"] }
    end

    def sensitive_attribute?(key)
      key.match?(PRIVATE_KEY) || key.match?(::Ingest::PiiScrubbing::SENSITIVE_KEY)
    end

    def any_value(value, depth:)
      raise Rejected, "Attribute nesting exceeded" if depth > 8
      value = object(value || {})
      known = value.keys & %w[stringValue boolValue intValue doubleValue arrayValue kvlistValue bytesValue]
      return {} if known.empty?
      raise Rejected, "Invalid attribute value" unless known.one?
      key = known.first
      decoded = case key
      when "stringValue" then text(value[key])
      when "boolValue" then boolean(value[key])
      when "intValue" then integer(value[key], min: -(2**63), max: (2**63) - 1).to_s
      when "doubleValue" then finite_number(value[key])
      when "arrayValue"
        { "values" => array(object(value[key])["values"]).map { |item| any_value(item, depth: depth + 1) } }
      when "kvlistValue"
        { "values" => attributes(object(value[key])["values"], depth: depth + 1) }
      when "bytesValue"
        raise Rejected, "Invalid bytes" unless value[key].is_a?(String)
        decoded_bytes = Base64.strict_decode64(value[key]).force_encoding(Encoding::UTF_8)
        Base64.strict_encode64(text(decoded_bytes))
      end
      { key => decoded }
    rescue ArgumentError
      raise Rejected, "Invalid bytes"
    end

    def finite_number(value)
      raise Rejected, "Invalid number" unless (value.is_a?(Numeric) && value.finite?) || %w[NaN Infinity -Infinity].include?(value)
      value
    end

    def boolean(value)
      raise Rejected, "Invalid boolean" unless [ true, false ].include?(value)
      value
    end

    def resource(value)
      value = object(value || {})
      { "attributes" => attributes(value["attributes"]), "droppedAttributesCount" => integer(value.fetch("droppedAttributesCount", 0), max: (2**32) - 1) }
    end

    def scope(value)
      value = object(value || {})
      resource(value).merge("name" => text(value["name"]), "version" => text(value["version"]))
    end
  end
end
