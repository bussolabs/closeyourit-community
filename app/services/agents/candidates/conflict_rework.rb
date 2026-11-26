# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1346, CYRA-1154 — a delivery waiting for a person (or approved and waiting for the staging release)
    # no longer merges with main. The first time the work goes back to the agent marked for the resolution
    # round (CYAU-300); if that round was already used, it stops and says why. One path for the six-hour
    # recheck (RecheckWaiting) and for the check that runs when main moves (ConflictChecks::SendBack).
    #
    # The caller has already read GitHub and is inside its own transaction: nothing here calls the network.
    class ConflictRework < ApplicationService
      SOURCE = "candidate_check"

      # A person who looked at this delivery and said no keeps the last word: nothing moves it by itself.
      def self.held_by_person?(workflow)
        Ticketing::Event.where(ticket_id: workflow.ticket_id, action: "review_rejected")
                        .exists?([ "created_at >= ?", workflow.candidate_verified_at ])
      end

      # `round_used:` lets the caller say what the workflow mark cannot: the mark is cleared at every delivery,
      # so a delivery born from a resolution round looks like a fresh one.
      def initialize(workflow:, candidate:, now: Time.current, round_used: nil, detail: nil)
        @workflow = workflow
        @candidate = candidate
        @now = now
        @round_used = round_used.nil? ? workflow.conflict_resolution_requested_at.present? : round_used
        @detail = detail
      end

      def call
        @round_used ? stop! : send_back!
        Result.ok(@round_used ? :stopped : :sent_back)
      end

      private

      # Approved work loses its approval too, as when the staging release meets the same conflict
      # (Attempts::Effects::CloserStaging): the resolved head goes back to a person's review.
      def send_back!
        @workflow.send_phase_back_to_work!("autopilot")
        @workflow.reload.update!(**Agents::Workflow.conflict_round(@now), **Agents::Workflow.autopilot_rework(@now))
      end

      def stop!
        reason = "merge_conflict on #{@candidate.repository_full_name}##{@candidate.number}"
        reason = "#{reason} — #{@detail}" if @detail.present?
        Agents::Workflows::BlockExhaustedPhase.call(workflow: @workflow, phase: "autopilot", source: SOURCE, reason:)
      end
    end
  end
end
