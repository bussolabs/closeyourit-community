# frozen_string_literal: true

FactoryBot.define do
  factory :github_installation, class: "Github::Installation" do
    association :organization
    sequence(:installation_id) { |n| 1_000_000 + n }
    account_login { "bussolabs" }
  end
end
