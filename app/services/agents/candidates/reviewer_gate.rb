# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1297 — leaves to a person a delivery re-read by the same engine that wrote it: a machine set to
    # review its own work gave the delivery no second pair of eyes.
    class ReviewerGate < DeliveryGate
      ACTION_STOPPED = "delivery_review_stopped"
      ACTION_WOULD_STOP = "delivery_review_would_stop"
      REASON = "self_review"

      Verdict = Data.define(:engine) do
        def review? = engine.present?
        def to_h = { reasons: [ REASON ], engine: }
      end

      private

      def read_verdict
        attempt = @candidate.attempt
        return if attempt.nil?

        Verdict.new(engine: attempt.reviewer_runtime == attempt.runtime ? attempt.runtime : nil)
      end

      def record!(verdict)
        record_event!(enforcing? ? ACTION_STOPPED : ACTION_WOULD_STOP, verdict.to_h) if verdict.review?
      end
    end
  end
end
