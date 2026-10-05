# frozen_string_literal: true

FactoryBot.define do
  factory :team, class: "Teams::Team" do
    organization
    sequence(:name) { |n| "Team #{n}" }
  end
end
