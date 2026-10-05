# frozen_string_literal: true

FactoryBot.define do
  factory :feature_status, class: "Types::FeatureStatus" do
    association :organization
    sequence(:code) { |n| "feature_status_#{n}" }
    label { "Planned" }
    color { "sky" }
    position { 0 }
    category { :planned }

    # Stati "rilasciati": è su questi che ci si aspetta una versione.
    trait :available do
      code { "available" }
      label { "Available" }
      color { "emerald" }
      category { :available }
    end

    trait :deprecated do
      code { "deprecated" }
      label { "Deprecated" }
      color { "amber" }
      category { :deprecated }
    end

    trait :in_development do
      code { "in_development" }
      label { "In development" }
      color { "indigo" }
      category { :in_development }
    end

    trait :not_applicable do
      code { "not_applicable" }
      label { "Not applicable" }
      color { "gray" }
      category { :not_applicable }
    end

    trait :inactive do
      active { false }
    end
  end
end
