# frozen_string_literal: true

module Agents
  # CYRA-1034 — the latest release of the programs a machine reports, so its page can say which ones
  # have an update. A daily job fills the cache; the page only reads it and never calls out.
  # Node and Python are compared within their own release line: a new major is a choice, not an update.
  module RuntimeVersions
    SOURCES = {
      "node" => [ :eol, "nodejs" ],
      "python" => [ :eol, "python" ],
      "claude" => [ :npm, "@anthropic-ai/claude-code" ],
      "codex" => [ :npm, "@openai/codex" ],
      "opencode" => [ :npm, "opencode-ai" ],
      "pnpm" => [ :npm, "pnpm" ],
      "cyi" => [ :npm, "@bussolabs/closeyourit-cli" ]
    }.freeze

    # Longer than a day, so one failed check keeps the previous answer instead of emptying the column.
    CACHE_TTL = 3.days
    NUMBER = /\d+(?:\.\d+)+/

    module_function

    def refresh!(npm: Agents::Registries::Npm.new, eol: Vulnerabilities::Eol::Client.new)
      SOURCES.each do |name, (kind, product)|
        value = kind == :npm ? npm.latest(product) : eol.cycles(product)&.map { |c| c.slice("cycle", "latest") }
        Rails.cache.write(cache_key(name), value, expires_in: CACHE_TTL) if value.present?
      rescue Agents::Registries::Client::Error, Vulnerabilities::Eol::Client::Error => e
        Rails.logger.warn("[runtime_versions] #{name}: #{e.code}")
      end
    end

    # { latest:, outdated: } for a program this module follows, nil otherwise or before the first check.
    def status(name, raw_version)
      current = number(raw_version)
      return nil unless current && SOURCES.key?(name)

      latest = latest_for(name, current)
      return nil unless latest && Gem::Version.correct?(latest)

      { latest:, outdated: Gem::Version.new(latest) > Gem::Version.new(current) }
    end

    def number(raw) = raw.to_s[NUMBER]

    def latest_for(name, current)
      cached = Rails.cache.read(cache_key(name))
      return cached unless cached.is_a?(Array)

      cached.find { |cycle| line_of(current, cycle["cycle"]) }&.dig("latest")
    end

    # "24" matches 24.x.y, "3.12" matches 3.12.z.
    def line_of(current, cycle) = current == cycle.to_s || current.start_with?("#{cycle}.")

    def cache_key(name) = "agents:runtime_versions:#{name}"
  end
end
