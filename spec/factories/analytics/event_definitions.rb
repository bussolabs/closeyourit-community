# frozen_string_literal: true

FactoryBot.define do
  factory :analytics_event_definition, class: "Analytics::EventDefinition" do
    project
    sequence(:name) { |n| "Signup#{n}" }
    property_names { %w[plan] }
  end
end
