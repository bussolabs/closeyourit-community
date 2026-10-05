# frozen_string_literal: true

FactoryBot.define do
  factory :server_host, class: "Servers::Host" do
    association :organization
    sequence(:fingerprint) { |n| format("%024x", n) }
    sequence(:name) { |n| "host-#{n}" }
    hostname { name }
    status { :pending }

    trait :up do
      status { :up }
      # Due istanti distinti di proposito (CYRA-649): last_push_at è quando la macchina ha
      # parlato (lo scrive il controller), last_seen_at l'ora della fotografia che ha mandato.
      last_push_at { Time.current }
      last_seen_at { Time.current }
    end

    trait :down do
      status { :down }
    end

    trait :paused do
      status { :paused }
    end

    trait :revoked do
      revoked_at { Time.current }
    end
  end
end
