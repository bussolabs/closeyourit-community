# frozen_string_literal: true

module Agents
  module Tester
    # CYAU-329 — what the Tester measured on a delivery, written in the ticket history every time. The gate
    # (Candidates::TesterGate) speaks only where a delivery could move on by itself: on a project whose
    # deliveries always wait for a person nothing said whether the proofs ran, passed or failed.
    class DeliveryRecord
      ACTION = "delivery_tester_ran"

      def self.call(...) = new(...).call

      # `block` is the delivered payload's: the attempt is written after the phase effect, so it does not carry it yet.
      def initialize(workflow:, block:)
        @workflow = workflow
        @report = Report.parse(block)
      end

      def call
        return if project.tester_mode == Agents::Candidates::ScopeCheck::MODE_OFF
        return unless @report.present? && @report.moment == Report::MOMENT_DELIVERY

        # No actor, a system name: a program wrote this row, not a person (CYRA-406).
        Ticketing::RecordActivity.call(
          ticket: @workflow.ticket, action: ACTION, actor_name: I18n.t("member.tickets.activity.system.autopilot"),
          data: { engine: @report.engine, commit: @report.commit, mode: project.tester_mode, **by_status }
        )
      end

      private

      def project = @workflow.ticket.project

      def by_status
        %w[passed failed not_run].index_with do |status|
          @report.results.select { |entry| entry["status"] == status }.map { |entry| entry["criterion_id"] }
        end.symbolize_keys
      end
    end
  end
end
