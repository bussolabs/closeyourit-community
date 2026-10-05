# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "timeout"

module Ingest
  # Puma spills both large and chunked bodies before Rack. Verify its actual temporary filesystem.
  module VolatileStorage
    module_function

    def verify!
      path = File.realpath(Dir.tmpdir)
      valid = if RUBY_PLATFORM.include?("linux")
        linux_tmpfs?(path)
      elsif RUBY_PLATFORM.include?("darwin")
        macos_ramdisk?(path)
      else
        false
      end
      raise "Crash ingestion requires TMPDIR on a verified volatile filesystem" unless valid
      true
    rescue SystemCallError, JSON::ParserError, Timeout::Error
      raise "Crash ingestion requires TMPDIR on a verified volatile filesystem"
    end

    def contains?(mount, path)
      path == mount || path.start_with?(mount.delete_suffix("/") + "/")
    end

    def linux_tmpfs?(path)
      mounts = File.readlines("/proc/self/mountinfo").filter_map do |line|
        fields, filesystem = line.split(" - ", 2)
        mount = fields.split[4].gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }
        [ mount, filesystem.split.first ] if contains?(mount, path)
      end
      mounts.max_by { |mount, _type| mount.length }&.last == "tmpfs"
    end

    def macos_ramdisk?(path)
      Timeout.timeout(3) do
        plist, status = Open3.capture2("/usr/bin/hdiutil", "info", "-plist", err: File::NULL)
        return false unless status.success?
        json, status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", "-", stdin_data: plist, err: File::NULL)
        return false unless status.success?
        df, status = Open3.capture2("/bin/df", "-P", path, err: File::NULL)
        return false unless status.success?
        device = df.lines.last.to_s.split.first
        JSON.parse(json).fetch("images", []).any? do |image|
          image["image-path"].to_s.match?(/\Aram:\/\/[0-9]+\z/) && image.fetch("system-entities", []).any? do |entity|
            entity["dev-entry"] == device && entity["mount-point"].is_a?(String) && contains?(entity["mount-point"], path)
          end
        end
      end
    end
  end
end
