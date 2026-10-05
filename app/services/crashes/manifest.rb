# frozen_string_literal: true

module Crashes
  # The isolated parser's output remains untrusted. Only diagnostic fields cross this boundary.
  class Manifest < ApplicationService
    def initialize(value)
      @value = value
    end

    def call
      raise Rejected, "invalid_report" unless @value.is_a?(Hash) && @value["schema_version"] == 1
      result = { "schema_version" => 1, "symbolication" => "unavailable" }
      result["system_info"] = fields(@value["system_info"], %w[os cpu_arch os_version]) if @value.key?("system_info")
      result["crash_info"] = fields(@value["crash_info"], %w[type address crashing_thread]) if @value.key?("crash_info")
      result["modules"] = collection(@value["modules"], 512).map { |item| fields(item, %w[base_addr end_addr code_id debug_id filename]) }
      result["threads"] = collection(@value["threads"], 128).map do |thread|
        fields(thread, %w[thread_id]).merge("frames" => collection(thread["frames"], 256).map { |frame| fields(frame, %w[instruction module module_offset trust]) })
      end
      raise Rejected, "report_too_large" if result.to_json.bytesize > MAX_REPORT - 32.kilobytes
      result
    end

    private

    def collection(value, max)
      return [] if value.nil?
      raise Rejected, "invalid_report" unless value.is_a?(Array) && value.size <= max && value.all? { |item| item.is_a?(Hash) }
      value
    end

    def fields(value, keys)
      return {} if value.nil?
      raise Rejected, "invalid_report" unless value.is_a?(Hash)
      value.slice(*keys).transform_keys(&:to_s).each_with_object({}) do |(key, item), result|
        next if item.nil?
        if %w[thread_id crashing_thread].include?(key)
          raise Rejected, "invalid_report" unless item.is_a?(Integer) && item.between?(0, 0xffffffff)
        else
          raise Rejected, "invalid_report" unless item.is_a?(String)
        end
        item = clean_string(key, item) if item.is_a?(String)
        result[key] = item
      end
    end

    def clean_string(key, item)
      raise Rejected, "invalid_report" if !item.valid_encoding? || item.include?("\0") || item.bytesize > 4096
      item = item.tr("\\", "/").split("/").last.to_s if %w[filename module].include?(key)
      if %w[debug_id code_id instruction module_offset base_addr end_addr address].include?(key)
        raise Rejected, "invalid_report" unless item.match?(/\A[0-9a-fA-FxX-]{1,256}\z/)
        item
      else
        Errors::Ingest::Scrub.call(payload: item)
      end
    end
  end
end
