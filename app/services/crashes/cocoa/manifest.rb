# frozen_string_literal: true

module Crashes
  module Cocoa
    class Manifest < ApplicationService
      MAX_ADDRESS = (2**64) - 1

      def initialize(payload:)
        @payload = payload
      end

      def call
        raise Rejected, "unsupported_cocoa_profile" unless @payload.is_a?(Hash) && @payload["platform"] == "cocoa"
        os = @payload.dig("contexts", "os", "name")
        architecture = @payload.dig("contexts", "device", "arch")
        raise Rejected, "unsupported_cocoa_profile" unless [ "macOS", "Mac OS X", "iOS" ].include?(os) && %w[arm64 x86_64].include?(architecture)
        threads = collection(@payload.dig("threads", "values"), 128)
        raise Rejected, "native_budget" if threads.sum { |thread| collection(thread.dig("stacktrace", "frames"), 256).size } > 500
        modules = collection(@payload.dig("debug_meta", "images"), 512).map { |image| native_image(image) }
        result = { "schema_version" => 1, "system_info" => { "os" => os, "cpu_arch" => architecture }, "modules" => modules, "crash_info" => crash_info(threads),
          "threads" => threads.map { |thread| native_thread(thread) } }
        ::Crashes::Manifest.call(result)
      rescue TypeError, ArgumentError, ::Artifacts::Rejected
        raise Rejected, "invalid_cocoa_manifest"
      end

      private

      def crash_info(threads)
        indices = threads.each_index.select { |index| threads[index]["crashed"] == true }
        raise Rejected, "ambiguous_cocoa_thread" if indices.size > 1
        { "crashing_thread" => indices.first }
      end

      def collection(value, limit)
        return [] if value.nil?
        raise Rejected, "native_budget" unless value.is_a?(Array) && value.size <= limit && value.all? { |item| item.is_a?(Hash) }
        value
      end

      def native_image(image)
        raise Rejected, "invalid_cocoa_image" unless image["type"] == "macho"
        base = address(image["image_addr"])
        size = image["image_size"]
        raise Rejected, "invalid_cocoa_image" unless size.is_a?(Integer) && size.positive? && base + size <= MAX_ADDRESS
        identity = ::Artifacts::NativeSymbols::Identity.debug_id(image["debug_id"])
        { "base_addr" => "0x#{base.to_s(16)}", "end_addr" => "0x#{(base + size).to_s(16)}", "debug_id" => identity, "filename" => image["code_file"] }
      end

      def native_thread(thread)
        frames = collection(thread.dig("stacktrace", "frames"), 256).reverse.map do |frame|
          result = { "trust" => "sentry" }
          result["instruction"] = "0x#{address(frame['instruction_addr']).to_s(16)}" if frame["instruction_addr"]
          result
        end
        { "thread_id" => thread["id"], "frames" => frames }
      end

      def address(value)
        raise Rejected, "invalid_cocoa_address" unless value.is_a?(String) && value.match?(/\A0x[0-9a-f]{1,16}\z/i)
        value.to_i(16)
      end
    end
  end
end
