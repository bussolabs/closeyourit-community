# frozen_string_literal: true

module Projects
  # The outcome of one test in one run (CYRA-1165). `known_failure` is decided when the run arrives:
  # a failure covered by a known failure still valid then shows as known, any other as new.
  class TestResult < ApplicationRecord
    self.table_name = "projects_test_results"

    # The error message is kept short: the full output stays in the CI log.
    MESSAGE_LIMIT = 2_000

    belongs_to :test_run, class_name: "Projects::TestRun", inverse_of: :results
    belongs_to :test_case, class_name: "Projects::TestCase", inverse_of: :results

    validates :status, inclusion: { in: TestCase::STATUSES }

    def failed? = status == "failed"
  end
end
