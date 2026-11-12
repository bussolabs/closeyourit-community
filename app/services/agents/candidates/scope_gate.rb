# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1291 — reads the files the pull request really changed and leaves to a person what ScopeCheck flags.
    # Files outside the plan and removed tests are only recorded (CYRA-1292).
    class ScopeGate < DeliveryGate
      ACTION_STOPPED = "delivery_scope_stopped"
      ACTION_WOULD_STOP = "delivery_scope_would_stop"
      ACTION_OUTSIDE_PLAN = "delivery_scope_outside_plan"
      ACTION_TESTS_REMOVED = "delivery_scope_tests_removed"

      private

      def client = @client ||= Github::Client.new

      # An unreadable file list is not a clean one: switched on it goes to a person, in a dry run it says nothing.
      def read_verdict
        files = client.pull_request_files(@candidate.repository.github_installation_id,
                                          @candidate.repository_full_name, @candidate.number)
        check(paths: files[:paths], truncated: files[:truncated], files: files[:files])
      rescue Github::Client::Error
        enforcing? ? check(paths: [], truncated: true) : nil
      end

      def check(paths:, truncated:, files: [])
        ScopeCheck.call(paths:, declared_paths:, organization: @workflow.organization, project:, truncated:, files:)
      end

      def record!(verdict)
        action = action_for(verdict)
        record_event!(action, verdict.to_h) if action
        record_event!(ACTION_TESTS_REMOVED, verdict.to_h.slice(:tests_removed, :tests_delta)) if verdict.tests_weakened?
      end

      def action_for(verdict)
        return enforcing? ? ACTION_STOPPED : ACTION_WOULD_STOP if verdict.review?

        ACTION_OUTSIDE_PLAN if verdict.outside_plan.any?
      end
    end
  end
end
