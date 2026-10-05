# frozen_string_literal: true

FactoryBot.define do
  factory :secret_version, class: "Secrets::Version" do
    secret_variable
    sequence(:number) { |n| n }
    value { "snapshot-value" }
  end
end
