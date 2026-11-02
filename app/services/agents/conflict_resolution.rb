# frozen_string_literal: true

module Agents
  # CYAU-300 — the attempt that resolves a code conflict with main runs on Codex and is reviewed by Claude, when
  # the machine has Codex; otherwise on the machine's usual engine. Same shape as the council's choice.
  module ConflictResolution
    ENGINE = "codex"
    REVIEWER = "claude"

    def self.choice_for(workflow:, host:)
      return nil if workflow.conflict_resolution_requested_at.nil?
      return nil unless Council::WorkChoice.installed?(host, ENGINE)

      Council::WorkChoice::Choice.new(engine: ENGINE, model: nil, reviewer: REVIEWER)
    end
  end
end
