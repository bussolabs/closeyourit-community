# frozen_string_literal: true

FactoryBot.define do
  factory :server_enrollment_token, class: "Servers::EnrollmentToken" do
    association :organization
    sequence(:name) { |n| "fleet-#{n}" }
    token_prefix { "cyi_s_abc1" }
    sequence(:token_digest) { |n| Digest::SHA256.hexdigest("token-#{n}") }

    trait :revoked do
      revoked_at { Time.current }
    end
  end
end
