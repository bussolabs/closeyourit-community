# frozen_string_literal: true

module Agents
  module Supporters
    # CYRA-1197 — another agent looks at a stopped workflow before a person is called. The supporter reads why the
    # work stopped and recommends one of three things; the server decides:
    #   - "stop": the stopped agent tried to skip the system's gates or to harm production. Always applied: stopping
    #     is the safe direction, and only a person releases a safety stop.
    #   - "retry": the work goes back to the agent with the supporter's guidance, only when the server's own checks
    #     pass (score within the autonomous range, no reserved topic, no bypass in the guidance, confidence at
    #     least medium, retries left).
    #   - "escalate", or any check failing: the workflow stays with a person, as before.
    #   - a stop where the machine lost every attempt goes back like a machine retry: nothing in the work failed.
    # Every verdict is written to the ledger, pinned to the stop it read.
    class JudgeConsult < ApplicationService
      include Agents::Workflows::ConcludedTicketGate

      CONFIDENT = %w[medium high].freeze
      GUIDANCE_MIN = 20
      GUIDANCE_MAX = 2_000

      def initialize(host:, workflow_id:, payload:)
        @host = host
        @workflow_id = workflow_id
        @payload = payload.to_h.deep_stringify_keys
      end

      def call
        return error("R404-SUPPORTER-005", :consult_not_found) if workflow.nil?
        return error("R403-SUPPORTER-001", :disabled) unless project.supporter_enabled?

        digest = NextConsult.digest(workflow)
        decision = SupporterDecision.find_by(target_type: "consult", target_id: workflow.id, target_digest: digest)
        return Result.ok(summary(decision)) if decision
        return error("R409-SUPPORTER-005", :consult_stale) unless consultable? && @payload["digest"] == digest

        Result.ok(summary(decide(digest)))
      end

      private

      def workflow
        @workflow ||= Agents::Workflow.joins(ticket: :project)
          .where(projects: { organization_id: @host.organization_id }).find_by(id: @workflow_id)
      end

      def project = workflow.ticket.project
      def ticket = workflow.ticket
      def verdict = @verdict ||= (@payload["verdict"].is_a?(Hash) ? @payload["verdict"] : {})
      def guidance = verdict["guidance"].to_s.strip.truncate(GUIDANCE_MAX)

      def consultable?
        workflow.blocked_at? && !workflow.terminal? && NextConsult::CONSULTABLE_KINDS.include?(workflow.blocked_kind)
      end

      def decide(digest)
        return record!(digest, "stopped", RiskScore::RESERVED, []) if verdict["recommendation"] == "stop" && stop!

        judged = judgement
        outcome = judged[:reasons].empty? && retry! ? "retried" : "escalated"
        record!(digest, outcome, judged[:score], judged[:reasons], judged[:reserved], judged[:bypass])
      end

      def judgement
        text = [ ticket.title, ticket.description, workflow.blocked_reason, guidance ].join("\n")
        reserved = ReservedTopics.new(organization: project.organization, project: project).match(text: text)
        bypass = BypassGuard.match([ workflow.blocked_reason, guidance ].join("\n"))
        score = RiskScore.resolve(previous: nil, proposed: verdict["risk_score"], reserved: reserved.any?)
        { score:, reserved: reserved.map(&:value), bypass:, reasons: reasons(score, reserved, bypass) }
      end

      def reasons(score, reserved, bypass)
        [].tap do |list|
          unless machine_lost?
            list << "supporter_escalated" unless verdict["recommendation"] == "retry"
            list << "no_guidance" if guidance.length < GUIDANCE_MIN
            list << "risk_above_threshold" unless RiskScore.autonomous?(score)
            list << "low_confidence" unless CONFIDENT.include?(verdict["confidence"])
          end
          list << "reserved_topic" if reserved.any?
          list << "bypass_suspected" if bypass.any?
          list << "retries_exhausted" if retries >= NextConsult::MAX_RETRIES
          list << "ticket_concluded" if concluded_ticket?
        end
      end

      # Every attempt on the stopped phase was lost by the machine (restart, lease timeout): nothing in the work
      # failed, so the work goes back as a machine retry would, whatever the model made of the empty record. The
      # other checks (reserved topic, bypass, retries left, open ticket) still apply.
      def machine_lost?
        return @machine_lost if defined?(@machine_lost)

        statuses = workflow.attempts.where(phase: workflow.blocked_phase).order(created_at: :desc)
                           .limit(NextConsult::ATTEMPTS_SHOWN).pluck(:status)
        @machine_lost = workflow.blocked_kind == "attempt_limit" && statuses.any? && statuses.all?("stale")
      end

      def retries = SupporterDecision.where(target_type: "consult", workflow:, outcome: "retried").count

      # The same way out a person takes, without the CTO gate: the server's checks above are the gate here.
      def retry!
        result = Agents::Workflows::Unblock.call(workflow:, actor: nil, by_supporter: true)
        return false unless result.ok?

        Ticketing::RecordActivity.call(ticket:, action: "workflow_supporter_retried",
                                       actor_name: I18n.t("agents.supporter.activity_actor"), data: {})
        true
      end

      def stop!
        reason = [ verdict["rationale"], Array(verdict["bypass_signals"]).join(", ") ].compact_blank.join(" — ")
        Agents::Workflows::SafetyStop.call(workflow:, reason: reason.presence || "stopped by the supporter",
                                           actor_name: I18n.t("agents.supporter.activity_actor"))
      end

      def record!(digest, outcome, score, reasons, reserved = [], bypass = [])
        SupporterDecision.create!(
          organization: project.organization, workflow:, target_type: "consult", target_id: workflow.id,
          target_digest: digest, outcome:, engine: @host.effective_supporter, risk_score: score,
          evidence: verdict.merge("guidance" => guidance, "blocked_kind" => workflow.blocked_kind,
                                  "reserved_matches" => reserved, "bypass_matches" => bypass, "reasons" => reasons)
        )
      end

      def summary(decision)
        { outcome: decision.outcome, workflow_id: decision.target_id, risk_score: decision.risk_score,
          reasons: Array(decision.evidence["reasons"]) }
      end

      def error(code, key)
        status = { "R404" => :not_found, "R403" => :forbidden, "R409" => :conflict }.fetch(code[0, 4])
        Result.err(AppError.new(I18n.t("agents.supporter.errors.#{key}"), code: code, status: status))
      end
    end
  end
end
