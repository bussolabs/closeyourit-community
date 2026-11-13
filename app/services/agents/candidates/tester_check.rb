# frozen_string_literal: true

module Agents
  module Candidates
    # CYAU-329 — reads the Tester's outcome against the proofs the approved plan asks to RUN (a done criterion
    # verified by a test or a command). Every such proof passed, on the delivered commit, by an engine other
    # than the one that wrote the work — or a person decides. Pure: it trusts the shape, not the overall status.
    class TesterCheck
      KINDS = %w[test command].freeze

      Verdict = Data.define(:reasons, :failed, :missing, :engine, :owed) do
        def owed? = owed
        def review? = reasons.any?
        def to_h = { reasons:, failed:, missing:, engine: }
      end

      def self.call(...) = new(...).call

      def self.owed_ids(criteria)
        Array(criteria).filter_map do |criterion|
          next unless criterion.is_a?(Hash) && KINDS.include?(criterion.dig("verification", "kind"))

          criterion["id"].presence
        end
      end

      def initialize(report:, criteria:, commit:, writer:)
        @report = report
        @ids = self.class.owed_ids(criteria)
        @commit = commit
        @writer = writer
      end

      def call
        Verdict.new(reasons:, failed:, missing:, engine: @report&.engine, owed: @ids.any?)
      end

      private

      def reasons
        return [] if @ids.empty?
        return [ "tester_absent" ] unless delivery_report?

        list = []
        list << "tester_stale" if @commit.blank? || @report.commit != @commit
        list << "tester_same_engine" if @report.engine == @writer
        list << "tester_failed" if failed.any?
        list << "tester_incomplete" if missing.any?
        list
      end

      def delivery_report? = @report.present? && @report.moment == Tester::Report::MOMENT_DELIVERY

      def failed = delivery_report? ? @ids.select { |id| @report.status_of(id) == Tester::Report::FAILED } : []

      # Not run, or not in the outcome at all.
      def missing
        return [] unless delivery_report?

        @ids.reject { |id| [ Tester::Report::PASSED, Tester::Report::FAILED ].include?(@report.status_of(id)) }
      end
    end
  end
end
