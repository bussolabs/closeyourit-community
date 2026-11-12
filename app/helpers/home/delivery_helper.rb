# frozen_string_literal: true

module Home
  # What a delivery says about itself on an approval card: the counted evidence, the questions it
  # left on the ticket and its short recap. Split from HomeHelper, which had outgrown one file.
  module DeliveryHelper
    # CYRA-886 — what a delivery claims, counted from the agent's work report. Every number is stated by
    # the agent (`reported`), never verified here, and the page says so.
    # CYRA-1284 — a check has three states: one that was not run is neither passed nor failed.
    DeliveryEvidence = Data.define(:criteria_done, :criteria_total, :tests_done, :tests_total, :tests_failed, :deviations) do
      def tests_not_run = tests_total - tests_done - tests_failed

      # The worst state among the checks: "failed", else "not_run", else "passed".
      def tests_state
        return "failed" if tests_failed.positive?

        tests_not_run.positive? ? "not_run" : "passed"
      end
    end

    def delivery_evidence(attempt)
      report = attempt&.result.to_h["work_report"]
      return unless report.is_a?(Hash)

      criteria = Array(report["acceptance_evidence"])
      tests = Array(report["tests"])
      DeliveryEvidence.new(criteria_done: criteria.count { |item| item.to_h["status"] == "verified" },
                           criteria_total: criteria.size,
                           tests_done: tests.count { |item| item.to_h["status"] == "passed" },
                           tests_total: tests.size,
                           tests_failed: tests.count { |item| item.to_h["status"] == "failed" },
                           deviations: Array(report["deviations"]).map(&:to_h))
    end

    # CYRA-1288 — the questions a delivery left on its ticket, oldest first, withdrawn ones out. Empty
    # where the card is not a delivery: a plan has its own questions, asked in its own round.
    def delivery_questions(card)
      return [] unless card.delivered_work? && card.ticket

      card.ticket.questions.readable_by(Current.account, organization: Current.organization)
          .where(closed_at: nil).chronological.includes(:resolved_answer).to_a
    end

    def delivery_decision_card(attempt)
      card = attempt&.result.to_h["decision_card"]
      card if card.is_a?(Hash) && card["headline"].present?
    end
  end
end
