# frozen_string_literal: true

FactoryBot.define do
  factory :metric_group, class: "Metrics::Group" do
    association :project
    sequence(:fingerprint) { |n| "metric-fingerprint-#{n}" }
    title { "SELECT * FROM users WHERE id = ?" }
    kind { :slow_query }
    samples_count { 1 }
    duration_total_ms { 150.0 }
    duration_min_ms { 150.0 }
    duration_max_ms { 150.0 }
    first_seen_at { Time.current }
    last_seen_at { Time.current }

    trait :slow_method do
      kind { :slow_method }
      title { "Checkout#total" }
    end

    trait :performance_issue do
      kind { :performance_issue }
      subtype { "n_plus_one" }
      title { "n_plus_one SELECT * FROM users WHERE id = <n> app/models/order.rb:42" }
    end
  end
end
