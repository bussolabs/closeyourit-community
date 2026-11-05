# frozen_string_literal: true

module Projects
  module TestRuns
    # A test that both passed and failed on the same commit is flaky (CYRA-1165): the code did not
    # change, the outcome did. Looks at the runs of the commit of `run` within FLAKY_LOOKBACK, only
    # at the tests of that run, and stamps them with the time of the run that revealed it.
    class DetectFlaky < ApplicationService
      def initialize(run:)
        @run = run
      end

      def call
        ids = flaky_case_ids
        return 0 if ids.empty?

        TestCase.where(id: ids).where("flaky_at IS NULL OR flaky_at < ?", @run.ran_at)
                .update_all(flaky_at: @run.ran_at, flaky_sha: @run.sha, updated_at: Time.current)
      end

      private

      def flaky_case_ids
        same_commit = TestRun.where(project_id: @run.project_id, sha: @run.sha)
                             .where(ran_at: TestRun::FLAKY_LOOKBACK.ago..).or(TestRun.where(id: @run.id))
        TestResult.where(test_run_id: same_commit.select(:id), status: %w[passed failed])
                  .where(test_case_id: @run.results.select(:test_case_id))
                  .group(:test_case_id).having("COUNT(DISTINCT status) = 2").pluck(:test_case_id)
      end
    end
  end
end
