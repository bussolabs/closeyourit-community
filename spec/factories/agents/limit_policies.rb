# frozen_string_literal: true

FactoryBot.define do
  factory :agent_limit_policy, class: "Agents::LimitPolicy" do
    association :organization
    project { nil }
    runtime { nil }
    max_parallel { nil }
    max_daily_runs { nil }
    max_daily_cost { nil }
    max_runtime_seconds { nil }
    stop_dispatch { false }
    max_age_seconds { 60 }
  end
end
