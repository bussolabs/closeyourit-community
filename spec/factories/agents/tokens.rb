# frozen_string_literal: true

FactoryBot.define do
  factory :agent_token, class: "Agents::Token" do
    association :organization
    sequence(:name) { |n| "automator-#{n}" }
    token_prefix { "cyi_a_abc1" }
    sequence(:token_digest) { |n| Digest::SHA256.hexdigest("agent-token-#{n}") }

    trait :revoked do
      revoked_at { Time.current }
    end
  end
end
