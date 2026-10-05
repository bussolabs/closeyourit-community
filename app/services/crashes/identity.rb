# frozen_string_literal: true

module Crashes
  module Identity
    module_function

    def metadata(event)
      { "release" => event.release, "environment" => event.environment, "dist" => event.payload["dist"].presence }
    end

    def compatible_build?(payload, manifest)
      images = payload.dig("debug_meta", "images") if payload["debug_meta"].is_a?(Hash)
      return true unless images.is_a?(Array) && manifest.present?
      modules = manifest.fetch("modules", [])
      images.all? do |image|
        next true unless image.is_a?(Hash)
        keys = %w[debug_id code_id].select { |key| image[key].present? }
        keys.empty? || modules.any? { |entry| keys.all? { |key| canonical(entry[key], key) == canonical(image[key], key) } }
      end
    end

    def canonical(value, key)
      value = value.to_s.downcase
      return value unless key == "debug_id"
      # Sentry UUIDs omit a zero appendix; Breakpad always appends hexadecimal age.
      uuid = /\A([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})(?:-([0-9a-f]{1,8}))?\z/.match(value)
      return [ uuid.captures.first(5).join, uuid[6].to_s.to_i(16) ] if uuid
      compact = /\A([0-9a-f]{32})([0-9a-f]{1,8})?\z/.match(value)
      return [ compact[1], compact[2].to_s.to_i(16) ] if compact
      value
    end
  end
end
