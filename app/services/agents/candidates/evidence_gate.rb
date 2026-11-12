# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1292 — leaves to a person a delivery whose proofs are incomplete or whose tests did not pass.
    class EvidenceGate < DeliveryGate
      ACTION_STOPPED = "delivery_evidence_stopped"
      ACTION_WOULD_STOP = "delivery_evidence_would_stop"

      private

      def read_verdict
        EvidenceCheck.call(work_report: @candidate.attempt&.result.to_h["work_report"], criterion_ids:)
      end

      # The "done when" of the approved plan that carry an id. An older plan lists plain sentences: none to match.
      def criterion_ids
        @workflow.frozen_plan&.document&.definition_of_done.to_a.filter_map { |criterion| criterion["id"] }
      end

      def record!(verdict)
        record_event!(enforcing? ? ACTION_STOPPED : ACTION_WOULD_STOP, verdict.to_h) if verdict.review?
      end
    end
  end
end
