# frozen_string_literal: true

FactoryBot.define do
  factory :analytics_salt, class: "Analytics::Salt" do
    sequence(:date) { |n| Time.current.utc.to_date - n }
    value { SecureRandom.hex(32) }
  end
end
