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
        reserved = ReservedTopics.new(organization: project.organization, project: project).match(text: text, paths: paths)
        score = RiskScore.resolve(previous: nil, proposed: verdict["risk_score"], reserved: reserved.any?, paths: paths)
        { score:, reserved: reserved.map(&:value), reasons: reasons(score, reserved) }
      end

      # The files the plan itself names, so a supporter that forgets one cannot hide it.
      def plan_paths
        plan.document.work_items.flat_map { |item| Array(item.to_h["files"]) }.filter_map { |file| file.to_h["path"].presence }
      end

      def reasons(score, reserved)
        [].tap do |list|
          list << "supporter_escalated" unless verdict["recommendation"] == "approve"
          list << "risk_above_threshold" unless RiskScore.autonomous?(score)
          list << "reserved_topic" if reserved.any?
          list << "low_confidence" unless CONFIDENT.include?(verdict["confidence"])
          list << "ticket_concluded" if concluded_ticket?
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

      def record!(judged, digest, outcome)
        SupporterDecision.create!(
          organization: project.organization, workflow:, target_type: "plan", target_id: plan.id,
          target_digest: digest, outcome:, engine: @host.effective_supporter, risk_score: judged[:score],
          evidence: verdict.merge("plan_version" => plan.version, "reserved_matches" => judged[:reserved],
                                  "reasons" => judged[:reasons])
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
