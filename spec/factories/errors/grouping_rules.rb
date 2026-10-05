# frozen_string_literal: true

FactoryBot.define do
  factory :error_grouping_rule, class: "Errors::GroupingRule" do
    association :project
    field { :exception_type }
    operator { :contains }
    sequence(:value) { |n| "Error#{n}" }
    sequence(:fingerprint_key) { |n| "group-#{n}" }
    position { 0 }
    active { true }
  end
end
