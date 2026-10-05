# frozen_string_literal: true

FactoryBot.define do
  factory :alerting_notification, class: "Alerting::Notification" do
    association :organization
    association :account
    subject { association(:error_group) }
    via { :in_app }
    event_type { :error_new }
    title { "New error · RuntimeError" }
    body { "undefined method `total' for nil" }
    url { "/member/monitoring/error/1" }
    sequence(:dedup_key) { |n| "dedup-#{n}" }
    status { :sent }

    trait :unread do
      read_at { nil }
    end

    trait :read do
      read_at { Time.current }
    end

    trait :email do
      via { :email }
    end
  end
end
