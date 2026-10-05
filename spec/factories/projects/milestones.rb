# frozen_string_literal: true

FactoryBot.define do
  factory :milestone, class: "Projects::Milestone" do
    association :project
    sequence(:code) { |n| "milestone_#{n}" }
    label { "v1.0" }
    color { "indigo" }
    position { 0 }
    due_on { nil }
  end
end
