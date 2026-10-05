# frozen_string_literal: true

module Guides
  module Installation
    class Catalog < ApplicationService
      MAX_BYTES = 5.megabytes
      MAX_RECORDS = 10_000
      SECRET = /cyi_(?:[a-z]_)?[A-Za-z0-9_-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(?:Bearer|Basic)\s+(?!\[REDACTED\])[^\s"\],]+|\b(?:Authorization|Cookie|Set-Cookie|X-Api-Key):\s*(?!\s*\[REDACTED\])\S+|https?:\/\/[^\/\s]+@|(?:[?&]|\b)(?:token|api[_-]key|password|secret)=(?!\[REDACTED\])[^\s&]+/i
      SECRET_KEY = /\A(?:authorization|proxy.authorization|cookie|set.cookie|password|secret|token|api.key|access.token|client.secret|dsn)\z/i

      def initialize(directory: Rails.root.join("config/installation_catalog"))
        @directory = Pathname(directory)
      end

      def call
        lock = parse(read("LOCK.json", 4096))
        schema = pinned("schema.json", lock)
        snapshot = pinned("observations.json", lock)
        validator = JSONSchemer.schema(schema, regexp_resolver: "ecma", format: true,
          ref_resolver: ->(_uri) { raise Unavailable, "External catalog references are disabled" })
        raise Unavailable, "Catalog schema is invalid" unless validator.valid?(snapshot)
        raise Unavailable, "Catalog contains a credential pattern" if secret?(snapshot)
        records = snapshot.fetch("observations")
        raise Unavailable, "Catalog record budget exceeded" if records.size > MAX_RECORDS
        raise Unavailable, "Catalog contains duplicate observations" unless records.map { |row| row.fetch("run_id") }.uniq.size == records.size
        records.each { |row| validate_claim!(row) }
        records.sort_by { |row| [ Time.iso8601(row.fetch("finished_at")), row.fetch("run_id") ] }.reverse
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError, SystemCallError,
        JSONSchemer::InvalidRefPointer, JSONSchemer::InvalidRefResolution, JSONSchemer::UnknownRef,
        JSONSchemer::UnknownVocabulary, JSONSchemer::InvalidEcmaRegexp, JSONSchemer::InvalidRegexpResolution
        raise Unavailable, "Installation catalog is unavailable"
      end

      private

      def read(name, limit = MAX_BYTES)
        path = @directory.join(name)
        raise Unavailable, "Catalog must be a regular file" if path.symlink? || !path.file?
        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          raw = file.read(limit + 1)
          raise Unavailable, "Catalog byte budget exceeded" if raw.bytesize > limit
          raw
        end
      end

      def parse(raw) = JSON.parse(raw, max_nesting: 32, allow_duplicate_key: false)

      def pinned(name, lock)
        raw = read(name)
        raise Unavailable, "Catalog pin mismatch" unless Digest::SHA256.hexdigest(raw) == lock.fetch("files").fetch(name)
        parse(raw)
      end

      def secret?(value)
        case value
        when Hash then value.any? { |key, child| (key.match?(SECRET_KEY) && ![ nil, "", "[REDACTED]" ].include?(child)) || secret?(child) }
        when Array
          value.each_with_index.any? do |child, index|
            flag = child.is_a?(String) && child.match?(/\A--(?:token|password|api-key|secret|dsn)\z/)
            (flag && index + 1 < value.size && value[index + 1] != "[REDACTED]") || secret?(child)
          end
        when String then value.match?(SECRET)
        else false
        end
      end

      def validate_claim!(row)
        claim, tuple = row.values_at("claim", "tuple")
        if row["profile"] == "sentry-errors-v1" && claim != "implemented"
          raise Unavailable, "Error-only observations cannot promote support"
        end
        return if claim == "implemented"
        if tuple.dig("backend", "dirty") || row.fetch("capabilities").any? { |cap| cap["required"] && cap["status"] != "pass" }
          raise Unavailable, "Incomplete observations cannot promote support"
        end
        return unless claim == "released"
        package = tuple.fetch("package")
        if package["origin"] != "registry" || package.dig("source", "dirty") || !package.key?("registry") || tuple.dig("backend", "deployment") == "local"
          raise Unavailable, "Local observations cannot claim release"
        end
      end
    end
  end
end
