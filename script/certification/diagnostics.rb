# frozen_string_literal: true

require "json"

module Certification
  # Store only rejection codes and counts; full log messages may contain credentials.
  class Diagnostics
    MAX_BYTES = 128 * 1024
    REJECTION = /\AMetrics::IngestJob (\d+) [^\n]{1,100}: (R422-METRIC-00[23]) project_id=([0-9a-f-]{36})\n?\z/

    def initialize(path)
      @path = path
    end

    def write(message)
      match = REJECTION.match(message)
      return message.bytesize unless match

      line = JSON.generate(code: match[2], count: Integer(match[1], 10), project_id: match[3]) + "\n"
      File.open(@path, File::WRONLY | File::APPEND | File::CREAT | File::NOFOLLOW, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write(line) if file.size + line.bytesize <= MAX_BYTES
      end
      message.bytesize
    end

    def close; end

    def self.read(path, project_id:)
      return [] unless File.file?(path)

      rows = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        file.flock(File::LOCK_SH)
        raise "Certification diagnostic artifact is oversized" if file.size > MAX_BYTES

        file.each_line.map { |line| JSON.parse(line, symbolize_names: true) }
      end
      valid = rows.all? do |row|
        row.is_a?(Hash) && %w[R422-METRIC-002 R422-METRIC-003].include?(row[:code]) &&
          row[:count].is_a?(Integer) && row[:count].positive?
      end
      raise "Invalid certification diagnostic artifact" unless valid

      rows.select { |row| row[:project_id] == project_id }.group_by { |row| row[:code] }.map do |code, entries|
        { code:, count: entries.sum { |entry| entry.fetch(:count) } }
      end
    rescue JSON::ParserError, Errno::ELOOP
      raise "Invalid certification diagnostic artifact"
    end
  end
end
