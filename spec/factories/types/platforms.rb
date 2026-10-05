# frozen_string_literal: true

FactoryBot.define do
  factory :platform, class: "Types::Platform" do
    association :organization
    sequence(:code) { |n| "platform_#{n}" }
    label { "Platform" }
    color { "sky" }
    position { 0 }
    supports_uptime { false }

    # Piattaforma web/server (abilita la sezione uptime sui progetti che la usano).
    trait :uptime_capable do
      supports_uptime { true }
    end
  end
end
