# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1292 — reads the proofs a delivery declares against the "done when" of its plan. A proof that is
    # partial or missing, a criterion with no proof, a failed or skipped test: a person decides.
    # Pure. It reads what the agent reported: it says what is missing, it does not prove what is claimed.
    class EvidenceCheck
      COMPLETE = "verified"

      Verdict = Data.define(:reasons, :incomplete, :absent, :tests_failed, :tests_not_run) do
        def review? = reasons.any?
        def to_h = { reasons:, incomplete:, absent:, tests_failed:, tests_not_run: }
      end

      def self.call(...) = new(...).call

      def initialize(work_report:, criterion_ids:)
        @report = work_report.is_a?(Hash) ? work_report : {}
        @criterion_ids = Array(criterion_ids).compact
      end

      def call
        Verdict.new(reasons:, incomplete:, absent:, tests_failed:, tests_not_run:)
      end

      private

      def reasons
        list = []
        list << "evidence_incomplete" if incomplete.any?
        list << "evidence_absent" if absent.any?
        list << "tests_failed" if tests_failed.positive?
        list << "tests_not_run" if tests_not_run.positive? || tests.empty?
        list
      end

      def evidence = @evidence ||= Array(@report["acceptance_evidence"]).map(&:to_h)
      def tests = @tests ||= Array(@report["tests"]).map(&:to_h)

      def incomplete
        @incomplete ||= evidence.reject { |item| item["status"] == COMPLETE }.filter_map { |item| item["criterion_id"] }
      end

      def absent = @absent ||= @criterion_ids - evidence.filter_map { |item| item["criterion_id"] }

      def tests_failed = tests.count { |item| item["status"] == "failed" }
      def tests_not_run = tests.count { |item| item["status"] == "not_run" }
    end
  end
end
