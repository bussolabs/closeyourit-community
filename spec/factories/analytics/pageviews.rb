# frozen_string_literal: true

FactoryBot.define do
  factory :pageview, class: "Analytics::Pageview" do
    project { association(:project) }
    name { "pageview" }
    sequence(:event_id) { |n| "pv-#{n}" }
    sequence(:visitor_hash) { |n| Digest::SHA256.hexdigest("visitor-#{n}") }
    hostname { "www.example.test" }
    path { "/" }
    referrer_host { nil }
    browser { "Chrome" }
    os { "macOS" }
    utm_source { nil }
    utm_medium { nil }
    utm_campaign { nil }
    environment { "production" }
    occurred_at { Time.current }
  end
end
