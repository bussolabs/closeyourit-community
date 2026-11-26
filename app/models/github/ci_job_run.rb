# frozen_string_literal: true

module Github
  # One finished attempt of a CI job, as GitHub's `workflow_job` event reports it (CYRA-1164).
  # GitHub gives every attempt its own job id, so `github_job_id` names the attempt: a delivery GitHub
  # repeats updates the same row. Kept RETENTION, pruned nightly by Github::PruneCiRunsJob.
  class CiJobRun < ApplicationRecord
    SUCCESS = "success"
    FAILURES = %w[failure timed_out].freeze
    # Only these say whether the job works; cancelled or neutral runs stay out of every figure.
    DECISIVE = ([ SUCCESS ] + FAILURES).freeze
    RETENTION = 90.days

    belongs_to :ci_job, class_name: "Github::CiJob", inverse_of: :runs

    validates :github_job_id, :run_id, :head_sha, :conclusion, :completed_at, presence: true
  end
end
