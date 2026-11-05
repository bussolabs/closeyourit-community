# frozen_string_literal: true

# CYRA-1165 — a recorded test run with its totals, and the failures that are new (not known), so the
# CI can print them: at most NEW_FAILURES_SHOWN, the full list is on the project's Tests tab.
class TestRunSerializer < ApplicationSerializer
  NEW_FAILURES_SHOWN = 50

  attributes :id, :version, :sha, :branch, :ran_at, :tests_count, :passed_count, :failed_count,
             :known_failed_count, :new_failed_count, :skipped_count, :duration_ms, :created_at

  attribute :new_failures do |run|
    run.results.where(status: "failed", known_failure: false).joins(:test_case)
       .order("projects_test_cases.file", "projects_test_cases.name").limit(NEW_FAILURES_SHOWN)
       .pluck("projects_test_cases.file", "projects_test_cases.name")
       .map { |file, name| { file: file, name: name } }
  end
end
