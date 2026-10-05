# frozen_string_literal: true

FactoryBot.define do
  factory :web_vital, class: "Analytics::WebVital" do
    project
    event_id { SecureRandom.uuid }
    metric { "lcp" }
    value { 2_400.0 }
    rating { "good" }
    hostname { "acme.example" }
    path { "/" }
    environment { "production" }
    device_type { "mobile" }
    navigation_type { "navigate" }
    occurred_at { Time.current }
    created_at { Time.current }

    trait :desktop do
      device_type { "desktop" }
    end
  end
end
