# frozen_string_literal: true

module Github
  # Figures per CI job of a repository over the last WINDOW (CYRA-1164), computed when the page is read.
  # A commit is flaky for a job when it failed and then passed on a new attempt. A job is flaky from
  # FLAKY_MIN_COMMITS such commits and FLAKY_MIN_RATE of its commits; it is worsening when its flaky
  # share beats the WINDOW before by WORSENING_POINTS.
  class CiHealth < ApplicationService
    WINDOW = 30.days
    FLAKY_MIN_COMMITS = 3
    FLAKY_MIN_RATE = 0.05
    WORSENING_POINTS = 0.05
    RECENT_COMMITS = 5

    Row = Data.define(:ci_job, :runs, :failures, :failure_rate, :avg_duration, :avg_queue,
                      :flaky_commits, :flaky_rate, :previous_flaky_rate, :recent_flaky_shas) do
      def flaky? = flaky_commits >= FLAKY_MIN_COMMITS && flaky_rate >= FLAKY_MIN_RATE

      def worsening?
        flaky? && !previous_flaky_rate.nil? && flaky_rate - previous_flaky_rate >= WORSENING_POINTS
      end
    end

    COLUMNS = %i[ci_job_id head_sha run_id run_attempt conclusion queued_at started_at completed_at].freeze
    Run = Struct.new(*COLUMNS, keyword_init: true)

    def initialize(repository:, now: Time.current)
      @repository = repository
      @now = now
    end

    def call
      runs = Github::CiJobRun.joins(:ci_job)
                             .where(github_ci_jobs: { repository_id: @repository.id })
                             .where(completed_at: (@now - (2 * WINDOW))..)
                             .where(conclusion: Github::CiJobRun::DECISIVE)
                             .pluck(*COLUMNS.map { |column| "github_ci_job_runs.#{column}" })
                             .map { |values| Run.new(**COLUMNS.zip(values).to_h) }
      current, previous = runs.partition { |run| run.completed_at >= @now - WINDOW }
      return Result.ok([]) if current.empty?

      jobs = @repository.ci_jobs.where(id: current.map(&:ci_job_id).uniq).includes(:ticket).index_by(&:id)
      previous_by_job = previous.group_by(&:ci_job_id)
      rows = current.group_by(&:ci_job_id).map do |job_id, job_runs|
        row(jobs.fetch(job_id), job_runs, previous_by_job.fetch(job_id, []))
      end
      Result.ok(rows.sort_by { |r| [ r.worsening? ? 0 : 1, r.flaky? ? 0 : 1, -r.flaky_rate, -r.failure_rate, r.ci_job.name ] })
    end

    private

    def row(ci_job, runs, previous_runs)
      failures = runs.count { |run| failure?(run) }
      commits = runs.group_by(&:head_sha)
      flaky = commits.select { |_sha, commit_runs| flaky_commit?(commit_runs) }
      Row.new(ci_job:, runs: runs.size, failures:, failure_rate: failures.fdiv(runs.size),
              avg_duration: average(runs) { |run| seconds(run.started_at, run.completed_at) },
              avg_queue: average(runs) { |run| seconds(run.queued_at, run.started_at) },
              flaky_commits: flaky.size, flaky_rate: flaky.size.fdiv(commits.size),
              previous_flaky_rate: flaky_rate(previous_runs),
              recent_flaky_shas: flaky.sort_by { |_sha, commit_runs| -commit_runs.map(&:completed_at).max.to_f }
                                      .first(RECENT_COMMITS).map(&:first))
    end

    def flaky_rate(runs)
      commits = runs.group_by(&:head_sha)
      return nil if commits.empty?

      commits.count { |_sha, commit_runs| flaky_commit?(commit_runs) }.fdiv(commits.size)
    end

    # Within a run the attempt number decides, since GitHub may deliver the green attempt before the red
    # one; across runs of the same commit, the order they finished in.
    def flaky_commit?(runs)
      retried = runs.group_by(&:run_id).values.any? do |attempts|
        failed = attempts.select { |run| failure?(run) }.map(&:run_attempt)
        passed = attempts.reject { |run| failure?(run) }.map(&:run_attempt)
        failed.any? && passed.any? && passed.max > failed.min
      end
      retried || rerun_passed?(runs)
    end

    def rerun_passed?(runs)
      first_failure = runs.select { |run| failure?(run) }.min_by(&:completed_at)
      return false if first_failure.nil?

      runs.any? { |run| !failure?(run) && run.run_id != first_failure.run_id && run.completed_at > first_failure.completed_at }
    end

    def failure?(run) = Github::CiJobRun::FAILURES.include?(run.conclusion)

    def average(runs)
      values = runs.filter_map { |run| yield(run) }
      values.empty? ? nil : values.sum.fdiv(values.size)
    end

    def seconds(from, to)
      return nil if from.nil? || to.nil? || to < from

      to - from
    end
  end
end
