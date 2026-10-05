# frozen_string_literal: true

FactoryBot.define do
  factory :alerting_preference, class: "Alerting::Preference" do
    association :organization
    association :account
    in_app_enabled { true }
    email_enabled { true }
    errors_enabled { true }
    uptime_enabled { true }

    trait :quiet_nights do
      quiet_hours_start { 22 }
      quiet_hours_end { 8 }
      quiet_hours_tz { "Europe/Rome" }
    end
  end
end
