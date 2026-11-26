# frozen_string_literal: true

FactoryBot.define do
  factory :github_ci_job, class: "Github::CiJob" do
    association :repository, factory: :github_repository
    workflow_name { "ci" }
    sequence(:job_name) { |n| "test-#{n}" }
  end

  factory :github_ci_job_run, class: "Github::CiJobRun" do
    association :ci_job, factory: :github_ci_job
    sequence(:github_job_id) { |n| 70_000_000 + n }
    sequence(:run_id) { |n| 9_000_000 + n }
    run_attempt { 1 }
    head_sha { SecureRandom.hex(20) }
    head_branch { "main" }
    conclusion { "success" }
    completed_at { 1.hour.ago }
    started_at { completed_at - 2.minutes }
    queued_at { started_at - 30.seconds }
  end
end
