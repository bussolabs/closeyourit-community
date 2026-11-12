# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1291 — a gate in front of a delivery that would move on by itself. The project chooses: off checks
    # nothing, a dry run records what the gate would have stopped, on leaves a flagged delivery to a person.
    # A subclass reads its own verdict and names its own ticket events.
    class DeliveryGate
      def self.stops?(...) = new(...).stops?

      def initialize(workflow:, candidate:, client: nil)
        @workflow = workflow
        @candidate = candidate
        @client = client
      end

      def stops?
        return false if mode == ScopeCheck::MODE_OFF

        verdict = read_verdict
        return false if verdict.nil?

        record!(verdict)
        enforcing? && verdict.review?
      end

      private

      def project = @workflow.ticket.project
      def mode = project.delivery_scope_check_mode
      def enforcing? = mode == ScopeCheck::MODE_ON

      # The files the approved plan names. No frozen plan, or one written before work items: nothing is named.
      def declared_paths
        items = @workflow.frozen_plan&.document&.work_items.to_a
        items.flat_map { |item| Array(item.to_h["files"]) }.filter_map { |file| file.to_h["path"].presence }
      end

      # No actor, a system name: a program wrote this row, not a person (CYRA-406).
      def record_event!(action, data)
        Ticketing::RecordActivity.call(
          ticket: @workflow.ticket, action:, actor_name: I18n.t("member.tickets.activity.system.autopilot"),
          data: data.merge(mode:, pull_request: @candidate.number)
        )
      end
    end
  end
end
