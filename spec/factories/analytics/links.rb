# frozen_string_literal: true

FactoryBot.define do
  factory :analytics_link, class: "Analytics::Link" do
    project
    enabled { true }

    trait :with_password do
      password { "segreto123" }
    end

    trait :disabled do
      enabled { false }
    end
  end
end
