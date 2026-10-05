# frozen_string_literal: true

module Artifacts
  module NativeSymbols
    module Identity
      FORMATS = %w[elf macho pdb pe].freeze
      ARCHITECTURES = %w[x86_64 arm64].freeze
      module_function

      def call(metadata:)
        raise Rejected, "invalid_native_identity" unless metadata.is_a?(Hash)
        format = metadata["format"]
        architecture = metadata["architecture"]
        raise Rejected, "unsupported_native_profile" unless FORMATS.include?(format) && ARCHITECTURES.include?(architecture)
        code = metadata["code_id"]
        if code
          raise Rejected, "invalid_code_id" unless code.is_a?(String) && code.match?(/\A[0-9a-fA-F]{1,128}\z/) && !code.match?(/\A0+\z/)
          code = code.downcase
        end
        raise Rejected, "missing_code_id" if format == "elf" && !code
        raise Rejected, "pdb_has_no_code_id" if format == "pdb" && code
        { format: format, architecture: architecture, debug_id: debug_id(metadata["debug_id"]), code_id: code }
      end

      def debug_id(value)
        raise Rejected, "invalid_debug_id" unless value.is_a?(String)
        match = /\A([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})(?:-([0-9a-f]{1,8}))?\z/i.match(value)
        compact = match ? match.captures.first(5).join : nil
        age = match && match[6]
        unless match
          match = /\A([0-9a-f]{32})([0-9a-f]{1,8})?\z/i.match(value)
          compact, age = match.captures if match
        end
        raise Rejected, "invalid_debug_id" unless compact && compact != "0" * 32
        uuid = compact.downcase.sub(/\A(.{8})(.{4})(.{4})(.{4})(.{12})\z/, '\\1-\\2-\\3-\\4-\\5')
        age.to_s.to_i(16).zero? ? uuid : "#{uuid}-#{age.to_i(16).to_s(16)}"
      end
    end
  end
end
