# frozen_string_literal: true

module Agents
  module Candidates
    # CYAU-329 — leaves to a person a delivery whose plan names proofs to run when the Tester did not run them
    # all, on the delivered commit, with an engine other than the writer's. The project chooses with its own
    # setting, apart from the other delivery gates: the Tester needs a machine that has it.
    class TesterGate < DeliveryGate
      ACTION_STOPPED = "delivery_tester_stopped"
      ACTION_WOULD_STOP = "delivery_tester_would_stop"

      private

      def mode = project.tester_mode

      def read_verdict
        attempt = @candidate.attempt
        return if attempt.nil?

        verdict = TesterCheck.call(report: attempt.tester_report, criteria:, commit: @candidate.head_sha, writer: attempt.runtime)
        verdict if verdict.owed?
      end

      def criteria = @workflow.frozen_plan&.document&.definition_of_done.to_a

      def record!(verdict)
        record_event!(enforcing? ? ACTION_STOPPED : ACTION_WOULD_STOP, verdict.to_h) if verdict.review?
      end
    end
  end
end
