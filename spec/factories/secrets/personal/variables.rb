# frozen_string_literal: true

FactoryBot.define do
  # Vault personale: scoped a [account, organization] (struttura flat, niente environment).
  factory :personal_secret_variable, class: "Secrets::Personal::Variable" do
    association :account
    association :organization
    sequence(:name) { |n| "PERSONAL_SECRET_#{n}" }
    value { "s3cr3t-value" }
  end

  factory :personal_secret_version, class: "Secrets::Personal::Version" do
    association :variable, factory: :personal_secret_variable
    sequence(:number) { |n| n }
    value { "s3cr3t-value" }
  end

  factory :personal_secret_event, class: "Secrets::Personal::Event" do
    association :account
    association :organization
    action { "set" }
    name { "PERSONAL_SECRET" }
    metadata { {} }
  end
end
