# frozen_string_literal: true

FactoryBot.define do
  factory :uptime_group, class: "Uptime::Group" do
    association :organization
    sequence(:name) { |n| "Uptime Group #{n}" }
    color { "indigo" }

    trait :published do
      public_status_enabled { true }
    end
  end
end
