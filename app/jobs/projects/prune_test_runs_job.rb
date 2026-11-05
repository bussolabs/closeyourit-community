# frozen_string_literal: true

module Projects
  # Retention of the test runs a CI sends (CYRA-1165): a suite of thousands of tests writes thousands
  # of rows per run. Runs older than TestRun::RETENTION go with their results (the foreign key
  # cascades); a test no run has named since then goes too, with its known-failure mark.
  class PruneTestRunsJob < ApplicationJob
    queue_as :batch

    BATCH = 500

    def perform
      cutoff = TestRun::RETENTION.ago
      TestRun.where(ran_at: ...cutoff).in_batches(of: BATCH).delete_all
      TestCase.where(last_run_at: ...cutoff).in_batches(of: BATCH).delete_all
    end
  end
end
