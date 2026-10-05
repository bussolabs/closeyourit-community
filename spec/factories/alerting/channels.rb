# frozen_string_literal: true

FactoryBot.define do
  factory :alerting_channel, class: "Alerting::Channel" do
    association :organization
    sequence(:name) { |n| "Canale #{n}" }
    kind { :webhook }
    config { { "url" => "https://hooks.example.test/cyi" } }
    webhook_secret { "s3cret" }
    enabled { true }
  end
end

FactoryBot.define do
  factory :alerting_rule_channel, class: "Alerting::RuleChannel" do
    association :rule, factory: :alerting_rule
    # Stessa org della regola (tenant-integrity validata sul model).
    channel { association(:alerting_channel, organization: rule.organization) }
  end
end
