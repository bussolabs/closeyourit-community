# frozen_string_literal: true

module Errors
  class Symbolication
    module Native
      class Stack < ApplicationService
        PROFILES = { "Linux" => "elf", "Mac OS X" => "macho", "macOS" => "macho", "Windows NT" => "pdb", "Windows" => "pdb" }.freeze
        ARCHITECTURES = { "amd64" => "x86_64", "x86_64" => "x86_64", "arm64" => "arm64", "aarch64" => "arm64" }.freeze

        def initialize(manifest:)
          @manifest = manifest
        end

        def call
          threads = @manifest.fetch("threads", [])
          raise ::Artifacts::Rejected, "native_budget" if threads.sum { |thread| thread.fetch("frames", []).size } > 500
          modules = @manifest.fetch("modules", []).each_with_index.map { |entry, index| module_info(entry, index) }
          threads.each_with_index.flat_map do |thread, thread_index|
            thread.fetch("frames", []).each_with_index.map do |frame, frame_index|
              resolve_frame(frame, thread_index, frame_index, modules)
            end
          end
        end

        private

        def resolve_frame(frame, thread_index, frame_index, modules)
          base = { "thread_index" => thread_index, "frame_index" => frame_index, "instruction" => frame["instruction"], "trust" => frame["trust"], "locations" => [] }
          position = hex(frame["instruction"])
          candidates = modules.select { |entry| contains?(entry, position) }
          reason = "invalid_address" if position.nil?
          reason ||= "missing_module" if candidates.empty?
          reason ||= "ambiguous_module" if candidates.size > 1
          if reason
            return base.merge("status" => reason)
          end
          mod = candidates.sole
          offset = position - mod[:base]
          reason = mod[:reason]
          reason ||= "invalid_address" if offset >= 0xffffffff || (frame.key?("module_offset") && hex(frame["module_offset"]) != offset)
          base.merge("module_index" => mod[:index], "module_offset" => frame.fetch("module_offset", "0x#{offset.to_s(16)}"), "status" => reason, "identity" => mod[:identity])
        end

        def contains?(entry, position)
          position && entry[:base] && entry[:finish] && position >= entry[:base] && position < entry[:finish]
        end

        def module_info(entry, index)
          base, finish = hex(entry["base_addr"]), hex(entry["end_addr"])
          reason = "invalid_address" unless base && finish && finish > base
          profile = PROFILES[@manifest.dig("system_info", "os")]
          architecture = ARCHITECTURES[@manifest.dig("system_info", "cpu_arch")]
          reason ||= "unsupported_profile" unless profile && architecture
          identity = ::Artifacts::NativeSymbols::Identity.call(metadata: { "format" => profile, "architecture" => architecture, "debug_id" => entry["debug_id"], "code_id" => (entry["code_id"] unless profile == "pdb") }) unless reason
          { index: index, base: base, finish: finish, identity: identity, reason: reason }
        rescue ::Artifacts::Rejected
          { index: index, base: base, finish: finish, reason: "missing_build_identity" }
        end

        def hex(value)
          return unless value.is_a?(String) && value.match?(/\A(?:0x)?[0-9a-fA-F]{1,16}\z/)
          value.to_i(16)
        end
      end
    end
  end
end
