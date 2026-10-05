# frozen_string_literal: true

FactoryBot.define do
  factory :cron_monitor, class: "Crons::Monitor" do
    association :project
    sequence(:slug) { |n| "job-#{n}" }
    name { "Nightly digest" }
    expected_interval_minutes { 60 }
    grace_minutes { 5 }
  end
end
