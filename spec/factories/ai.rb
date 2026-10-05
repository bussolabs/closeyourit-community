# frozen_string_literal: true

FactoryBot.define do
  factory :ai_request, class: "Ai::Request" do
    association :account
    association :organization
    kind { "error_triage" }
    args { { "group_id" => SecureRandom.uuid } }
  end
end
