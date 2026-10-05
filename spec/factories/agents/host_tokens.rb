# frozen_string_literal: true

FactoryBot.define do
  factory :agent_host_token, class: "Agents::HostToken" do
    host factory: :agent_host
    sequence(:token_digest) { |n| Digest::SHA256.hexdigest("agent-host-token-#{n}") }
    sequence(:token_prefix) { |n| "cyi_ah_#{n}" }

    trait :revoked do
      revoked_at { Time.current }
    end
  end
end
