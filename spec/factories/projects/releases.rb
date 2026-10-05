# frozen_string_literal: true

FactoryBot.define do
  factory :release, class: "Projects::Release" do
    association :project
    sequence(:version) { |n| "v0.0.#{n}" }
    environment { "production" }
  end
end
