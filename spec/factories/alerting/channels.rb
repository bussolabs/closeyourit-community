# frozen_string_literal: true

FactoryBot.define do
  factory :alerting_channel, class: "Alerting::Channel" do
    association :organization
    sequence(:name) { |n| "Canale #{n}" }
    kind { :webhook }
    config { { "url" => "https://hooks.example.test/cyi" } }
    webhook_secret { "s3cret" }
    enabled { true }

    # CYRA-1156 — a channel of the Slack app: the Slack channel code instead of an address.
    trait :slack_app do
      kind { :slack_app }
      config { { "slack_channel" => "C0123ABCD" } }
      webhook_secret { nil }
    end
  end
end

FactoryBot.define do
  factory :alerting_slack_message, class: "Alerting::SlackMessage" do
    association :organization
    channel { association(:alerting_channel, :slack_app, organization: organization) }
    event_type { "error_new" }
    subject { association(:error_group, project: association(:project, organization: organization)) }
    project { subject.project }
    slack_channel { channel.slack_channel }
    sequence(:slack_ts) { |n| "1700000000.#{n.to_s.rjust(6, '0')}" }
    title { "Nuovo errore · RuntimeError" }
    url { "/member/monitoring/errors/1" }
  end
end

FactoryBot.define do
  factory :alerting_rule_channel, class: "Alerting::RuleChannel" do
    association :rule, factory: :alerting_rule
    # Stessa org della regola (tenant-integrity validata sul model).
    channel { association(:alerting_channel, organization: rule.organization) }
  end
end
