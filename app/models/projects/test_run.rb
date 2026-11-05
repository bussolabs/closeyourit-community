# frozen_string_literal: true

module Projects
  # A run of a project's test suite sent by the CI (CYRA-1165): version, commit, branch, time and
  # totals. Unlike Projects::CoverageReport, which keeps only the last snapshot, every run is kept
  # until Projects::PruneTestRunsJob drops it, so each test builds a history.
  class TestRun < ApplicationRecord
    self.table_name = "projects_test_runs"

    # Caps on what a CI may send in one run (R-1 of the plan): the body before parsing, and the tests.
    MAX_PAYLOAD_BYTES = 8.megabytes
    MAX_TESTS = 20_000
    # How far back the same commit is looked at to call a test flaky.
    FLAKY_LOOKBACK = 14.days
    # How long a run is kept.
    RETENTION = 90.days

    belongs_to :project, class_name: "Projects::Project", inverse_of: :test_runs
    # The release with the same version, when the CI registered it; the run survives its pruning.
    belongs_to :release, class_name: "Projects::Release", optional: true

    has_many :results, class_name: "Projects::TestResult", foreign_key: :test_run_id, inverse_of: :test_run,
                       dependent: :delete_all

    normalizes :sha, with: ->(value) { value.to_s.strip.downcase }
    normalizes :branch, :version, with: ->(value) { value.to_s.strip.presence }

    validates :sha, presence: true
    validates :ran_at, presence: true

    scope :recent_first, -> { order(ran_at: :desc) }

    def short_sha = sha.to_s.first(7)

    # Failures not covered by a known failure still valid when the run arrived.
    def new_failed_count = failed_count - known_failed_count
  end
end
