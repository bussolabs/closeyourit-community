# frozen_string_literal: true

FactoryBot.define do
  factory :metric_sample, class: "Metrics::Sample" do
    group { association(:metric_group) }
    project { group.project }   # invariante: il sample eredita il progetto del gruppo
    sequence(:sample_id) { |n| "sample-#{n}" }
    kind { :slow_query }
    occurred_at { Time.current }
    duration_ms { 150.0 }
    environment { "production" }
    payload { { "sql" => "SELECT 1", "duration_ms" => 150.0 } }
  end
end
