# frozen_string_literal: true

FactoryBot.define do
  factory :test_run, class: "Projects::TestRun" do
    association :project
    sequence(:sha) { |n| format("%040x", n) }
    branch { "main" }
    ran_at { Time.current }
  end

  factory :test_case, class: "Projects::TestCase" do
    association :project
    file { "spec/models/user_spec.rb" }
    sequence(:name) { |n| "User behaves #{n}" }
    identity_digest { Projects::TestCase.digest_for(file, name) }
    last_status { "passed" }
    last_run_at { Time.current }
  end

  factory :test_result, class: "Projects::TestResult" do
    association :test_run
    test_case { association :test_case, project: test_run.project }
    status { "passed" }
  end

  factory :known_failure, class: "Projects::KnownFailure" do
    test_case
    project { test_case.project }
    expires_on { 14.days.from_now.to_date }
  end
end
