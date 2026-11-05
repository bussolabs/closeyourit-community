# frozen_string_literal: true

module Projects
  module TestRuns
    # Records a test run sent by the CI (CYRA-1165), in the one shape the CLI converts JUnit XML and
    # the other formats to: run metadata plus `tests` [{file, name, status, duration_ms, message}].
    # All or nothing: a report that breaks a rule is refused whole and nothing is written. Then the
    # same commit is looked at in the recent runs to mark flaky tests (DetectFlaky).
    class Record < ApplicationService
      Entry = Data.define(:digest, :file, :name, :status, :duration_ms, :message)

      STATUS_ALIASES = {
        "passed" => "passed", "pass" => "passed", "success" => "passed", "ok" => "passed",
        "failed" => "failed", "fail" => "failed", "failure" => "failed", "error" => "failed", "errored" => "failed",
        "skipped" => "skipped", "skip" => "skipped", "pending" => "skipped", "disabled" => "skipped"
      }.freeze
      # Worst outcome wins when a report names the same test twice (a retried example).
      STATUS_RANK = { "failed" => 2, "passed" => 1, "skipped" => 0 }.freeze
      NAME_LIMIT = 2_000
      FILE_LIMIT = 500
      SLICE = 1_000
      # The largest value the integer duration column holds.
      DURATION_CEILING = 2_147_483_647

      # A newer run decides the last status; one arriving late only adds to the history.
      CASE_ON_DUPLICATE = <<~SQL.squish
        last_status = CASE WHEN projects_test_cases.last_run_at IS NULL
                             OR EXCLUDED.last_run_at >= projects_test_cases.last_run_at
                           THEN EXCLUDED.last_status ELSE projects_test_cases.last_status END,
        last_run_at = GREATEST(projects_test_cases.last_run_at, EXCLUDED.last_run_at),
        updated_at = EXCLUDED.updated_at
      SQL

      def initialize(project:, params:)
        @project = project
        @params = params.to_h.with_indifferent_access
      end

      def call
        return invalid("R422-TESTRUN-001", "sha is required") if @params[:sha].to_s.strip.blank?

        tests = @params[:tests]
        return invalid("R422-TESTRUN-002", "tests must be a non-empty list") unless tests.is_a?(Array) && tests.any?
        if tests.size > TestRun::MAX_TESTS
          return invalid("R422-TESTRUN-003", "The report holds #{tests.size} tests, over the limit of #{TestRun::MAX_TESTS}")
        end

        entries, error = normalize(tests)
        return invalid("R422-TESTRUN-004", error) if error

        run = persist(entries)
        DetectFlaky.call(run: run)
        Result.ok(run)
      end

      private

      def persist(entries)
        known_ids = @project.known_failures.valid_on(Date.current).pluck(:test_case_id).to_set
        ApplicationRecord.transaction do
          run = create_run(entries)
          case_ids = upsert_cases(entries, run.ran_at)
          known = insert_results(run, entries, case_ids, known_ids)
          run.update_columns(known_failed_count: known) if known.positive?
          run
        end
      end

      def create_run(entries)
        counts = entries.map(&:status).tally
        version = @params[:version].to_s.strip.presence
        @project.test_runs.create!(
          release: release_for(version), version: version, sha: @params[:sha], branch: @params[:branch],
          ran_at: parse_time(@params[:ran_at]) || Time.current, tests_count: entries.size,
          passed_count: counts["passed"].to_i, failed_count: counts["failed"].to_i, skipped_count: counts["skipped"].to_i,
          duration_ms: integer_or_nil(@params[:duration_ms]) || entries.sum { _1.duration_ms.to_i }
        )
      end

      # The release with the same version, the production one first; none when the CI did not register it.
      def release_for(version)
        return nil if version.nil?

        releases = @project.releases.where(version: version)
        releases.find_by(environment: Release::DEFAULT_ENVIRONMENT) || releases.recent.first
      end

      def upsert_cases(entries, ran_at)
        entries.each_slice(SLICE).each_with_object({}) do |slice, ids|
          rows = slice.map do |entry|
            { project_id: @project.id, identity_digest: entry.digest, file: entry.file, name: entry.name,
              last_status: entry.status, last_run_at: ran_at }
          end
          saved = TestCase.upsert_all(rows, unique_by: %i[project_id identity_digest],
                                            on_duplicate: Arel.sql(CASE_ON_DUPLICATE),
                                            returning: %i[id identity_digest], record_timestamps: true)
          saved.each { |row| ids[row["identity_digest"]] = row["id"] }
        end
      end

      def insert_results(run, entries, case_ids, known_ids)
        known = 0
        entries.each_slice(SLICE) do |slice|
          rows = slice.map do |entry|
            case_id = case_ids.fetch(entry.digest)
            known_failure = entry.status == "failed" && known_ids.include?(case_id)
            known += 1 if known_failure
            { test_run_id: run.id, test_case_id: case_id, status: entry.status, known_failure: known_failure,
              duration_ms: entry.duration_ms, message: entry.message }
          end
          TestResult.insert_all!(rows, record_timestamps: true)
        end
        known
      end

      # [entries, nil] or [nil, error]: one entry per test identity, the worst outcome kept.
      def normalize(tests)
        by_digest = {}
        tests.each_with_index do |raw, index|
          entry, error = entry_for(raw, index)
          return [ nil, error ] if error

          kept = by_digest[entry.digest]
          by_digest[entry.digest] = entry if kept.nil? || STATUS_RANK[entry.status] > STATUS_RANK[kept.status]
        end
        [ by_digest.values, nil ]
      end

      def entry_for(raw, index)
        return [ nil, "tests[#{index}] is not an object" ] unless raw.is_a?(Hash)

        name = raw["name"].to_s.strip.first(NAME_LIMIT)
        return [ nil, "tests[#{index}] has no name" ] if name.blank?

        status = STATUS_ALIASES[raw["status"].to_s.strip.downcase]
        return [ nil, "tests[#{index}] has an unknown status: #{raw["status"].to_s.first(40)}" ] if status.nil?

        file = raw["file"].to_s.strip.first(FILE_LIMIT)
        [ Entry.new(digest: TestCase.digest_for(file, name), file: file, name: name, status: status,
                    duration_ms: integer_or_nil(raw["duration_ms"]),
                    message: raw["message"].to_s.first(TestResult::MESSAGE_LIMIT).presence), nil ]
      end

      # A duration in milliseconds, or nil when it is not a finite, non-negative number.
      def integer_or_nil(raw)
        value = Float(raw.to_s, exception: false)
        return nil unless value&.finite? && !value.negative?

        [ value.round, DURATION_CEILING ].min
      end

      def parse_time(raw)
        Time.iso8601(raw.to_s)
      rescue ArgumentError
        nil
      end

      def invalid(code, message)
        Result.err(AppError.new(message, code: code, status: :unprocessable_content))
      end
    end
  end
end
