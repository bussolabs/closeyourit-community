# frozen_string_literal: true

module Agents
  # Why a piece of work is stopped, in plain words: kind, phase and reason, for whoever has to decide.
  # The queue reads it once per row and the card once per card, so it is PURE and makes no query — the
  # reason sits on the workflow's own columns and the phase stalled under the attempts cap arrives
  # already resolved (Agents::Workflow#stop_reason passes it). CYRA-1329
  #
  # `blocked_reason` is an audit line, in one language and in a stable shape (see
  # Agents::Workflows::BlockExhaustedPhase): the sentence to read is composed HERE from the structured
  # fields. Member::AutomationSummary#blocked_line answers the same question on the ticket card and
  # stays its own: there the sentence counts the failed attempts (a query per row, an N+1 in a queue)
  # and names who is deciding, which a terminal row has no room for.
  class StopReason
    Note = Data.define(:kind, :phase, :reason)

    # CYRA-267 — rejected in review under the attempts cap: no blocked_* to read, yet the queue does
    # not propose the phase again. It is stopped, so it needs a kind of its own.
    STALLED_KIND = "stalled_review"

    def self.for(workflow:, stalled_phase: nil)
      return nil if workflow.nil? || workflow.terminal?
      return new(workflow).blocked_note if workflow.blocked_at?
      return nil if stalled_phase.blank?

      Note.new(kind: STALLED_KIND, phase: stalled_phase,
               reason: t("stalled_review", phase: phase_label(stalled_phase)))
    end

    # CYRA-1332 — a plan the supporter handed to a person is not stopped, yet whoever decides has to know
    # why it reached them: the reasons the server wrote with the verdict, in plain words, with the risk.
    HANDED_OVER_KIND = "plan_handed_over"

    def self.for_plan_decision(decision)
      return nil unless decision&.outcome == "escalated"

      reasons = Array(decision.evidence["reasons"]).uniq.map { |code| t("plan_reasons.#{code}", default: code.humanize) }
      reasons = [ t("plan_reasons.none") ] if reasons.empty?
      Note.new(kind: HANDED_OVER_KIND, phase: "planner",
               reason: t("plan_handed_over", risk: decision.risk_score, reasons: reasons.join("; ")))
    end

    # The phase names are the ones the ticket card already shows: a second set of names would make the
    # same phase read as two different steps.
    def self.phase_label(phase)
      I18n.t("member.tickets.automation.execution_phase.#{phase}", default: phase.to_s.humanize)
    end

    def self.t(key, **) = I18n.t("agents.stop_reason.#{key}", **)

    def initialize(workflow)
      @workflow = workflow
    end

    def blocked_note
      Note.new(kind: @workflow.blocked_kind, phase: @workflow.blocked_phase, reason: sentence)
    end

    private

    def sentence
      case @workflow.blocked_kind
      when "attempt_limit" then t("attempt_limit", phase: phase_label)
      when "held_by_person" then t("held_by_person", name: @workflow.held_by_name)
      when "production_approval" then t("production_approval")
      when "agent_blocked" then t("agent_blocked", phase: phase_label, reason: written_reason)
      when "review_fault" then t("review_fault", phase: phase_label)
      when "staging_deploy" then t("staging_deploy.#{Agents::Staging::VerifyMerge.deploy_stop_key(@workflow)}")
      else t(@workflow.blocked_kind, reason: written_reason, default: written_reason)
      end
    end

    # The agent's words with the audit prefix off: `agent_block_reason` drops the two composed ones,
    # the kind covers the rest (`safety_stop: …`, `candidate_check: …`).
    def written_reason
      @workflow.agent_block_reason.to_s.delete_prefix("#{@workflow.blocked_kind}: ").strip.presence ||
        t("no_reason")
    end

    def phase_label = self.class.phase_label(@workflow.blocked_phase)

    def t(key, **) = self.class.t(key, **)
  end
end
