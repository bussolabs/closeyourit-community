# frozen_string_literal: true

module Agents
  # CYAU-300 — the attempt that resolves a code conflict with main runs on Codex and is reviewed by Claude, when
  # the machine has Codex; otherwise on the machine's usual engine. Same shape as the council's choice.
  module ConflictResolution
    ENGINE = "codex"
    REVIEWER = "claude"

    # The only phase that can resolve a conflict: it is the one that writes on the branch.
    PHASE = "autopilot"

    # The mark outlives its round (it is cleared when the work completes), so it counts only for the phase that
    # can act on it: a planning session told to resolve a conflict stops, it cannot write (seen on AAC-13).
    def self.requested?(workflow:, phase:)
      workflow.conflict_resolution_requested_at.present? && phase.to_s == PHASE
    end

    def self.choice_for(workflow:, host:, phase:)
      return nil unless requested?(workflow:, phase:)
      return nil unless Council::WorkChoice.installed?(host, ENGINE)

      Council::WorkChoice::Choice.new(engine: ENGINE, model: nil, reviewer: REVIEWER)
    end
  end
end
