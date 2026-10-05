# frozen_string_literal: true

FactoryBot.define do
  factory :alerting_rule, class: "Alerting::Rule" do
    association :organization
    name { "Any new error" }
    event_type { :error_new }
    throttle_seconds { 300 }
    enabled { true }

    trait :regression do
      event_type { :error_regression }
    end

    trait :uptime_down do
      event_type { :uptime_down }
    end

    trait :uptime_up do
      event_type { :uptime_up }
    end

    trait :server_down do
      event_type { :server_down }
    end

    trait :disabled do
      enabled { false }
    end

    trait :scoped do
      project { association(:project, organization: organization) }
    end
  end
end
