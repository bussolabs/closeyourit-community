# frozen_string_literal: true

module Crashes
  module Elf
    class Manifest < ApplicationService
      MAX_ADDRESS = (2**64) - 1

      def initialize(payload:)
        @payload = payload
      end

      def call
        os = profile
        exceptions = collection(@payload.dig("exception", "values"), 10)
        raise Rejected, "invalid_elf_stack" if exceptions.empty?
        threads = exceptions.map { |exception| native_stack(exception) }
        raise Rejected, "native_budget" if threads.sum { |thread| thread["frames"].size } > 500
        images = collection(@payload.dig("debug_meta", "images"), 128)
        raise Rejected, "invalid_elf_image" if images.empty?
        unhandled = exceptions.each_index.select { |index| exceptions[index].dig("mechanism", "handled") == false }
        result = { "schema_version" => 1, "system_info" => { "os" => os, "cpu_arch" => @architecture },
          "modules" => images.map { |image| native_image(image) }, "threads" => threads,
          "crash_info" => { "crashing_thread" => (unhandled.first if unhandled.one?) } }
        ::Crashes::Manifest.call(result)
      rescue TypeError, ArgumentError, ::Artifacts::Rejected
        raise Rejected, "invalid_elf_manifest"
      end

      private

      def profile
        raise Rejected, "unsupported_elf_profile" unless @payload.is_a?(Hash) && @payload["platform"] == "native"
        os = @payload.dig("contexts", "os", "name")
        architectures = @payload.dig("contexts", "device", "archs")
        raise Rejected, "unsupported_elf_profile" unless %w[Android Linux].include?(os) && architectures.is_a?(Array) && architectures.one? && %w[arm64 x86_64].include?(architectures.first)
        @architecture = architectures.first
        os
      end

      def collection(value, limit)
        raise Rejected, "native_budget" unless value.is_a?(Array) && value.size <= limit && value.all? { |item| item.is_a?(Hash) }
        value
      end

      def native_image(image)
        raise Rejected, "invalid_elf_image" unless image["type"] == "elf" && [ nil, @architecture ].include?(image["arch"])
        base, size = address(image["image_addr"]), image["image_size"]
        raise Rejected, "invalid_elf_image" unless size.is_a?(Integer) && size.positive? && base + size <= MAX_ADDRESS
        result = { "base_addr" => "0x#{base.to_s(16)}", "end_addr" => "0x#{(base + size).to_s(16)}", "filename" => image["code_file"] }
        result["debug_id"] = ::Artifacts::NativeSymbols::Identity.debug_id(image["debug_id"]) if image["debug_id"]
        if image["code_id"]
          code = image["code_id"]
          raise Rejected, "invalid_elf_image" unless code.is_a?(String) && code.match?(/\A(?:[0-9a-f]{2}){4,64}\z/i) && !code.match?(/\A0+\z/)
          result["code_id"] = code.downcase
        end
        result
      end

      def native_stack(exception)
        frames = collection(exception.dig("stacktrace", "frames"), 256)
        raise Rejected, "invalid_elf_stack" if frames.empty?
        { "thread_id" => exception["thread_id"], "frames" => frames.reverse.map do |frame|
          { "instruction" => "0x#{address(frame['instruction_addr']).to_s(16)}", "trust" => "sentry" }
        end }
      end

      def address(value)
        raise Rejected, "invalid_elf_address" unless value.is_a?(String) && value.match?(/\A0x[0-9a-f]{1,16}\z/i)
        value.to_i(16)
      end
    end
  end
end
