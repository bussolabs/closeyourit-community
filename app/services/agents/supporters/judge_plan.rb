# frozen_string_literal: true

module Agents
  module Supporters
    # CYRA-1193 — the supporter judges a plan, the server decides. The plan is approved without a person only
    # when the supporter recommends it AND the server's own checks pass: the score raised by the server's rules
    # (never lowered) stays within the autonomous range, no reserved topic is hit by the text or the paths the
    # plan touches, and the confidence is at least medium. Otherwise the plan stays with a person. Every
    # verdict is written to the ledger, pinned to the plan version it read; approvals wait in "To review".
    class JudgePlan < ApplicationService
      include Agents::Workflows::ConcludedTicketGate

      CONFIDENT = %w[medium high].freeze
      # CYRA-1197 — how many times the supporter may send a plan back before a person decides.
      MAX_REVISIONS = 3
      # CYRA-1197 — after the last revision a plan up to this risk is approved and its remaining gaps travel to the
      # implementer as notes: review, CI and the staging soak still stand before production.
      ACCEPT_WITH_NOTES_MAX = 5
      # A built-in word in the text is cleared with medium confidence only up to this risk.
      MEDIUM_CLEAR_MAX = 2
      NOTES_MAX = 4_000

      def initialize(host:, plan_id:, payload:)
        @host = host
        @plan_id = plan_id
        @payload = payload.to_h.deep_stringify_keys
      end

      def call
        return error("R404-SUPPORTER-004", :plan_not_found) if plan.nil?
        return error("R403-SUPPORTER-001", :disabled) unless project.supporter_enabled?

        digest = NextPlan.digest(plan)
        decision = SupporterDecision.find_by(target_type: "plan", target_id: plan.id, target_digest: digest)
        return Result.ok(summary(decision)) if decision
        return error("R409-SUPPORTER-004", :plan_stale) unless judgeable? && @payload["digest"] == digest

        judged = judgement
        # CYRA-1197 — a plan that tries to skip the system's gates or to harm production stops the workflow.
        return Result.ok(summary(record!(judged, digest, "stopped"))) if verdict["recommendation"] == "stop" && stop!

        # CYRA-1197 — fixable gaps go back to the planner with the findings, never past the bypass guard.
        return Result.ok(summary(record!(judged, digest, "retried"))) if revise?(judged) && request_changes!

        outcome = judged[:reasons].empty? && approve! ? "approved" : "escalated"
        Result.ok(summary(record!(judged, digest, outcome)))
      end

      private

      def plan
        @plan ||= Agents::Plan.joins(workflow: { ticket: :project })
          .where(projects: { organization_id: @host.organization_id }).find_by(id: @plan_id)
      end

      def workflow = plan.workflow
      def project = workflow.ticket.project
      def ticket = workflow.ticket
      def verdict = @verdict ||= (@payload["verdict"].is_a?(Hash) ? @payload["verdict"] : {})

      # Only the newest version of a plan still waiting for its approval can be judged.
      def judgeable?
        latest = workflow.plans.reorder(version: :desc).first
        latest == plan && plan.approved_at.nil? && plan.change_request.blank? && workflow.planned_at? &&
          workflow.approved_at.nil? && !workflow.cancelled_at? && !workflow.completed_at? && !workflow.blocked_at?
      end

      def judgement
        paths = (Array(verdict["touched_paths"]) + plan_paths).map(&:to_s).uniq
        text = [ ticket.title, ticket.description, NextPlan.document(plan) ].join("\n")
        matches = ReservedTopics.new(organization: project.organization, project: project).match(text: text, paths: paths)
        reserved = matches.reject { |entry| cleared?(entry) }
        score = RiskScore.resolve(previous: triage.applied, proposed: verdict["risk_score"], reserved: reserved.any?, paths: paths)
        bypass = BypassGuard.match(NextPlan.document(plan))
        { score:, reserved: matches.map(&:value), bypass:, reasons: reasons(score, reserved, bypass) }
      end

      # CYRA-1293 — what the triage said about the ticket: the floor under the supporter's own score.
      def triage = @triage ||= TriageRisk.for(workflow)

      # CYRA-1197 — a built-in word found only in the text ("billing", "pagamento") is cleared when the supporter
      # read the plan against the code and approves it with high confidence: the word alone is not a change to
      # money or data. A reserved path, a topic the organization or the project added, and the bypass guard
      # always stay in front.
      def cleared?(entry)
        entry.source == :built_in && !entry.path? && (approving? || accept_with_notes?) &&
          (verdict["confidence"] == "high" || (verdict["confidence"] == "medium" && proposed_risk <= MEDIUM_CLEAR_MAX))
      end

      def approving? = verdict["recommendation"] == "approve"
      def proposed_risk = verdict["risk_score"].to_i

      # The supporter asked for one more revision than the budget allows, on a plan it rates low risk.
      def accept_with_notes?
        # CYRA-1299 — a project with strict caps never approves a plan the supporter still wanted fixed.
        return false if project.strict_caps?

        verdict["recommendation"] == "revise" && revisions_exhausted? && proposed_risk.between?(1, ACCEPT_WITH_NOTES_MAX)
      end

      # What the implementer reads with the approved plan: the supporter's notes, or the gaps left after the
      # last revision. Model output: material to read, never orders.
      def implementation_notes
        notes = verdict["implementation_notes"].to_s.strip
        notes = Array(verdict["reasons_against"]).join("\n").strip if notes.empty? && accept_with_notes?
        notes.truncate(NOTES_MAX).presence
      end

      # The files the plan itself names, so a supporter that forgets one cannot hide it.
      def plan_paths
        plan.document.work_items.flat_map { |item| Array(item.to_h["files"]) }.filter_map { |file| file.to_h["path"].presence }
      end

      def reasons(score, reserved, bypass)
        [].tap do |list|
          unless approving? || accept_with_notes?
            list << "supporter_escalated"
            list << "revisions_exhausted" if verdict["recommendation"] == "revise" && revisions_exhausted?
          end
          list << "risk_above_threshold" unless RiskScore.autonomous?(score)
          list << "triage_risk" if triage.stops?
          list << "risk_above_threshold" if accept_with_notes? && score > ACCEPT_WITH_NOTES_MAX && list.exclude?("risk_above_threshold")
          list << "reserved_topic" if reserved.any?
          list << "bypass_suspected" if bypass.any?
          list << "low_confidence" unless CONFIDENT.include?(verdict["confidence"])
          list << "ticket_concluded" if concluded_ticket?
          # CYRA-1152 — approving a split creates tickets: always a person's yes.
          list << "epic_split" if plan.split?
        end
      end

      # The same freeze the CTO and the council apply, re-read under lock: a plan approved or changed meanwhile
      # is left alone and the verdict goes to the ledger as handed over.
      def approve!
        ApplicationRecord.transaction do
          workflow.lock!
          latest = workflow.plans.reorder(version: :desc).lock.first
          next false unless latest == plan && workflow.planned_at? && workflow.approved_at.nil? &&
                            latest.approved_at.nil? && latest.change_request.blank?

          Agents::Workflows::FreezePlan.call(workflow:, plan: latest, actor: nil, now: Time.current)
          Ticketing::RecordActivity.call(ticket:, action: "plan_supporter_approved",
                                         actor_name: I18n.t("agents.supporter.activity_actor"), data: {})
          true
        end
      end

      def revise?(judged)
        verdict["recommendation"] == "revise" && judged[:bypass].empty? && !revisions_exhausted? && !concluded_ticket?
      end

      def revisions_exhausted?
        @revisions_exhausted ||=
          SupporterDecision.where(workflow:, target_type: "plan", outcome: "retried").count >= MAX_REVISIONS
      end

      # Same reset a person's change request does: the planner phase is offered again and reads the findings.
      def request_changes!
        ApplicationRecord.transaction do
          workflow.lock!
          latest = workflow.plans.reorder(version: :desc).lock.first
          next false unless latest == plan && workflow.planned_at? && latest.approved_at.nil? &&
                            latest.change_request.blank?

          latest.update!(change_request: change_request_text)
          workflow.update!(planned_at: nil, approved_at: nil, approved_by: nil, **Agents::Workflow.cleared_block)
          true
        end
      end

      def change_request_text
        findings = Array(verdict["reasons_against"]).join("\n").strip
        [ I18n.t("agents.supporter.plan_revision_intro"), findings.presence || verdict["rationale"].to_s ].join("\n\n")
      end

      def stop!
        reason = [ verdict["rationale"], Array(verdict["bypass_signals"]).join(", ") ].compact_blank.join(" — ")
        Agents::Workflows::SafetyStop.call(workflow:, reason: reason.presence || "plan stopped by the supporter",
                                           actor_name: I18n.t("agents.supporter.activity_actor"))
      end

      def record!(judged, digest, outcome)
        SupporterDecision.create!(
          organization: project.organization, workflow:, target_type: "plan", target_id: plan.id,
          target_digest: digest, outcome:, engine: @host.effective_supporter, risk_score: judged[:score],
          evidence: verdict.merge("plan_version" => plan.version, "reserved_matches" => judged[:reserved],
                                  "guidance" => implementation_notes,
                                  "bypass_matches" => judged[:bypass],
                                  "reasons" => judged[:reasons], **triage.evidence)
        )
      end

      def summary(decision)
        { outcome: decision.outcome, plan_id: decision.target_id, risk_score: decision.risk_score,
          reasons: Array(decision.evidence["reasons"]) }
      end

      def error(code, key)
        status = { "R404" => :not_found, "R403" => :forbidden, "R409" => :conflict }.fetch(code[0, 4])
        Result.err(AppError.new(I18n.t("agents.supporter.errors.#{key}"), code: code, status: status))
      end
    end
  end
end
