# frozen_string_literal: true

FactoryBot.define do
  factory :agent_host, class: "Agents::Host" do
    association :organization
    sequence(:fingerprint) { |n| "automator-host-#{n}" }
    sequence(:hostname) { |n| "runner-#{n}" }
    platform { "linux" }
    arch { "amd64" }
    automator_version { "1.0.0" }
    # Certificato di default: gli spec di eligibilità/coda assumono un host abilitato all'esecuzione.
    certified_at { Time.current }

    trait :revoked do
      revoked_at { Time.current }
    end

    trait :uncertified do
      certified_at { nil }
    end
  end
end
