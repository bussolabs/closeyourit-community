# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1291 — reads the risk of a delivery on the files it really changed. The plan's risk is judged on the
    # files the plan names; this compares them with the pull request and says when a person must decide.
    # Pure: the caller fetches the files and the plan, and decides what a verdict stops.
    class ScopeCheck
      # Off checks nothing, dry run records what it would have stopped, on leaves the delivery to a person.
      MODE_OFF = "off"
      MODE_DRY_RUN = "dry_run"
      MODE_ON = "on"
      MODES = [ MODE_OFF, MODE_DRY_RUN, MODE_ON ].freeze
      # A change to the data structure cannot be undone by a rollback: a person decides, named or not.
      DATA_PATHS = [ %r{\Adb/}, %r{(\A|/)migrations?/} ].freeze
      # Where tests live, across the stacks the machines work on (CYRA-1292).
      TEST_PATHS = [ %r{(\A|/)(spec|test|tests|__tests__)/}, %r{[_.](spec|test)\.[a-z]+\z} ].freeze
      # How many paths a verdict keeps per list: the event is a record, not a copy of the diff.
      LISTED_MAX = 20

      Verdict = Data.define(:reasons, :score, :sensitive, :data, :reserved, :outside_plan, :files_count,
                            :tests_removed, :tests_delta) do
        def review? = reasons.any?
        # Deleted test files, or fewer test lines than before: recorded, never a stop by itself.
        def tests_weakened? = tests_removed.any? || tests_delta.negative?

        def to_h
          { reasons:, score:, files_count:, sensitive: sensitive.first(LISTED_MAX), data: data.first(LISTED_MAX),
            reserved: reserved.first(LISTED_MAX), outside_plan: outside_plan.first(LISTED_MAX),
            outside_plan_count: outside_plan.size, tests_removed: tests_removed.first(LISTED_MAX), tests_delta: }
        end
      end

      def self.call(...) = new(...).call

      def initialize(paths:, declared_paths:, organization:, project: nil, truncated: false, files: [])
        @files = Array(files).map { |file| file.to_h.symbolize_keys.merge(path: clean([ file.to_h.symbolize_keys[:path] ]).first) }
        @paths = clean(paths)
        @declared = clean(declared_paths).to_set
        @organization = organization
        @project = project
        @truncated = truncated
      end

      def call
        Verdict.new(reasons:, score:, sensitive:, data:, reserved:, outside_plan:, files_count: @paths.size,
                    tests_removed:, tests_delta:)
      end

      private

      def reasons
        list = []
        list << "files_unknown" if @truncated
        list << "data_change" if data.any?
        list << "sensitive_path_undeclared" if sensitive.any?
        list << "reserved_path_undeclared" if reserved.any?
        list
      end

      def data = @data ||= @paths.select { |path| DATA_PATHS.any? { |pattern| path.match?(pattern) } }

      # Access, CI, secrets, deploy and release files the approved plan did not name. Data has its own rule.
      def sensitive
        @sensitive ||= (outside_plan - data).select do |path|
          risk.sensitive?(path) || risk.sensitive?(path, risk::ROUTINE_SENSITIVE_PATHS)
        end
      end

      def reserved
        @reserved ||= begin
          prefixes = reserved_topics.entries.select(&:path?).map(&:value)
          outside_plan.select { |path| prefixes.any? { |prefix| path.downcase.start_with?(prefix) } }
        end
      end

      def test_files = @test_files ||= @files.select { |file| TEST_PATHS.any? { |pattern| file[:path].to_s.match?(pattern) } }
      def tests_removed = test_files.select { |file| file[:status] == "removed" }.map { |file| file[:path] }
      def tests_delta = test_files.sum { |file| file[:additions].to_i - file[:deletions].to_i }

      def outside_plan = @outside_plan ||= @paths.reject { |path| @declared.include?(path) }

      def score = risk.resolve(previous: nil, proposed: risk::RANGE.min, paths: @paths)

      def risk = Agents::Supporters::RiskScore

      def reserved_topics = Agents::Supporters::ReservedTopics.new(organization: @organization, project: @project)

      def clean(paths) = Array(paths).map { |path| path.to_s.delete_prefix("./").delete_prefix("/") }.reject(&:blank?).uniq
    end
  end
end
