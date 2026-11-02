# frozen_string_literal: true

module Agents
  # Fixed values of the council: Claude and Codex propose improvements, the server decides (CYRA-1133).
  module Council
    MODES = %w[off dry_run on].freeze
    OPEN_TICKET_CAP = 3
    MAX_PROPOSALS_PER_ENGINE = 3
    ENGINES = %w[claude codex].freeze
    MODELS = { "claude" => %w[claude-opus-5-5 claude-sonnet-5-5], "codex" => %w[gpt-6-astra] }.freeze
    RISKS = %w[low medium serious].freeze
    KINDS = %w[error code product].freeze
    TICKET_KINDS = { "error" => "bug", "code" => "task", "product" => "story" }.freeze
    RUN_INTERVAL = 24.hours
    RUN_STALE_AFTER = 2.hours
  end
end
