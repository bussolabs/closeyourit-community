# frozen_string_literal: true

module Agents
  module Tester
    # CYAU-329 — what the Tester saw on staging before the production tag, written in the ticket history. The
    # machine that takes the release runs the browser proofs of the plan first; here the server says whether
    # the delivery carries them, passed, on the released commit. A release without them is said out loud: the
    # tag is already out, so this is a record for who reads the ticket, not a gate.
    class ReleaseRecord
      ACTION_PASSED = "delivery_tester_release_passed"
      ACTION_MISSING = "delivery_tester_release_missing"

      def self.call(...) = new(...).call

      def initialize(workflow:, block:, commit:)
        @workflow = workflow
        @report = Report.parse(block)
        @commit = commit
      end

      def call
        return if mode == Agents::Candidates::ScopeCheck::MODE_OFF || criteria.empty?
        return record!(ACTION_PASSED) if proven?
        # A person gave the go-ahead: they did the proof themselves.
        return if @workflow.closer_production_approved_at?

        record!(ACTION_MISSING)
      end

      private

      def project = @workflow.ticket.project
      def mode = project.tester_mode

      def criteria
        @criteria ||= begin
          plan = @workflow.plans.where.not(approved_at: nil).reorder(version: :desc).first
          Array(plan&.definition_of_done).filter_map do |criterion|
            next unless criterion.is_a?(Hash) && criterion.dig("verification", "kind") == Agents::Workflows::BrowserProof::KIND

            criterion["id"].presence
          end
        end
      end

      def proven?
        @report.present? && @report.moment == Report::MOMENT_STAGING && @commit.present? && @report.commit == @commit &&
          criteria.all? { |id| @report.status_of(id) == Report::PASSED }
      end

      # No actor, a system name: a program wrote this row, not a person (CYRA-406).
      def record!(action)
        Ticketing::RecordActivity.call(
          ticket: @workflow.ticket, action:, actor_name: I18n.t("member.tickets.activity.system.autopilot"),
          data: { criteria:, engine: @report&.engine, mode: }
        )
      end
    end
  end
end
