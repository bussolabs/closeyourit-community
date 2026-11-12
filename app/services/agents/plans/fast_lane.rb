# frozen_string_literal: true

module Agents
  module Plans
    # CYRA-1300 — the fast lane: a small, low-risk plan is approved the moment the planner delivers it, with no
    # supporter and no person. Fixed rules only, no model decides. The project chooses: off does nothing, a dry
    # run records the plans that would have passed, on approves them. Review, CI and staging still stand, and
    # the delivery loses the lane when its real changes are larger than promised (Candidates::FastLaneGate).
    class FastLane
      MODES = Agents::Candidates::ScopeCheck::MODES
      MODE_OFF, MODE_DRY_RUN, MODE_ON = MODES
      # Counted on the files that are not tests: a test more is never a reason to slow down.
      MAX_FILES = 3
      ACTION_APPROVED = "plan_fast_lane_approved"
      ACTION_WOULD_APPROVE = "plan_fast_lane_would_approve"
      LOW_RISK = "low"

      def self.call(...) = new(...).call

      # True when the plan this workflow froze went through the fast lane.
      def self.taken?(workflow)
        workflow.frozen_plan_id.present? &&
          Ticketing::Event.where(ticket_id: workflow.ticket_id, action: ACTION_APPROVED)
                          .exists?([ "data->>'plan_id' = ?", workflow.frozen_plan_id ])
      end

      def self.work_files(paths)
        paths.reject { |path| Agents::Candidates::ScopeCheck::TEST_PATHS.any? { |pattern| path.match?(pattern) } }
      end

      def initialize(workflow:, plan:)
        @workflow = workflow
        @plan = plan
      end

      # True when the plan was approved here.
      def call
        return false if mode == MODE_OFF || reasons.any?
        return approve! if mode == MODE_ON

        record!(ACTION_WOULD_APPROVE)
        false
      end

      # Why the plan keeps the ordinary round; empty when it may take the fast lane.
      def reasons
        @reasons ||= [].tap do |list|
          list << "triage_not_low" unless triage_low?
          list << "no_files" if work_files.empty?
          list << "too_many_files" if work_files.size > MAX_FILES
          list << "sensitive_path" if paths.any? { |path| sensitive?(path) }
          list << "reserved_topic" if reserved?
          list << "bypass_suspected" if Agents::Supporters::BypassGuard.match(document_text).any?
          list << "epic_split" if @plan.split?
          list << "council_ticket" if Agents::CouncilProposal.exists?(ticket_id: ticket.id)
        end
      end

      private

      def ticket = @workflow.ticket
      def project = ticket.project
      def mode = project.fast_lane_mode

      # The files the plan names, as the delivery check reads them.
      def paths
        @paths ||= @plan.document.work_items.flat_map { |item| Array(item.to_h["files"]) }
                        .filter_map { |file| file.to_h["path"].to_s.delete_prefix("./").delete_prefix("/").presence }.uniq
      end

      def work_files = @work_files ||= self.class.work_files(paths)

      def sensitive?(path)
        risk = Agents::Supporters::RiskScore
        risk.sensitive?(path) || risk.sensitive?(path, risk::ROUTINE_SENSITIVE_PATHS) ||
          Agents::Candidates::ScopeCheck::DATA_PATHS.any? { |pattern| path.match?(pattern) }
      end

      # The newest triage that delivered a result, read whatever the project does with its risk elsewhere.
      def triage_low?
        result = @workflow.attempts.where(phase: "triage").order(created_at: :desc)
                          .filter_map { |attempt| attempt.result.presence }.first.to_h
        result["risk"] == LOW_RISK && result["requires_human_approval"] != true
      end

      def document_text = @document_text ||= Agents::Supporters::NextPlan.document(@plan)

      def reserved?
        text = [ ticket.title, ticket.description, document_text ].join("\n")
        Agents::Supporters::ReservedTopics.new(organization: project.organization, project:).match(text:, paths:).any?
      end

      # The same freeze the supporter applies, re-read under lock: a plan decided meanwhile is left alone.
      def approve!
        ApplicationRecord.transaction do
          @workflow.lock!
          latest = @workflow.plans.reorder(version: :desc).lock.first
          next false unless latest == @plan && @workflow.planned_at? && @workflow.approved_at.nil? &&
                            latest.approved_at.nil? && latest.change_request.blank? && !@workflow.cancelled_at? &&
                            !@workflow.completed_at?

          Agents::Workflows::FreezePlan.call(workflow: @workflow, plan: latest, actor: nil, now: Time.current)
          record!(ACTION_APPROVED)
          true
        end
      end

      # No actor, a system name: a rule approved this plan, not a person.
      def record!(action)
        Ticketing::RecordActivity.call(
          ticket:, action:, actor_name: I18n.t("member.tickets.activity.system.autopilot"),
          data: { plan_id: @plan.id, files: work_files.size, mode: }
        )
      end
    end
  end
end
