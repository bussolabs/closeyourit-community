# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-1197 — stop a workflow whose agent tried to skip the system's gates or to harm production (a manual
    # deploy, a force push to main, reading secrets, dropping data, skipping checks). Unlike Block it also
    # replaces a block already in place: a safety stop outranks any earlier reason. No machine path clears it;
    # only a person, through Unblock (see Agents::Workflow#safety_release).
    class SafetyStop < ApplicationService
      KIND = "safety_stop"

      def initialize(workflow:, reason:, actor_name:)
        @workflow = workflow
        @reason = reason
        @actor_name = actor_name
      end

      def call
        ApplicationRecord.transaction do
          @workflow.lock!
          next if @workflow.terminal? || @workflow.blocked_kind == KIND

          @workflow.update!(blocked_at: Time.current, blocked_kind: KIND,
                            blocked_phase: @workflow.blocked_phase.presence || @workflow.ready_execution_phase || "planner",
                            blocked_reason: "#{KIND}: #{@reason.to_s.squish.truncate(500)}")
          Ticketing::RecordActivity.call(ticket: @workflow.ticket, action: "agent_safety_stopped",
                                         actor_name: @actor_name, data: { reason: @reason.to_s.squish.truncate(300) })
        end
        true
      end
    end
  end
end
