# frozen_string_literal: true

FactoryBot.define do
  factory :uptime_announcement, class: "Uptime::Announcement" do
    association :monitor, factory: :uptime_monitor
    level { :maintenance }
    message { "Manutenzione programmata in corso." }
    active { true }
    starts_at { nil }
    ends_at { nil }

    # Finestra già passata → non live.
    trait :expired do
      starts_at { 2.hours.ago }
      ends_at { 1.hour.ago }
    end

    # Finestra futura → non ancora live.
    trait :scheduled do
      starts_at { 1.hour.from_now }
      ends_at { 3.hours.from_now }
    end

    trait :inactive do
      active { false }
    end
  end
end
