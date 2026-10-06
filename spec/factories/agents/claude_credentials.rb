# frozen_string_literal: true

FactoryBot.define do
  factory :agent_claude_credential, class: "Agents::ClaudeCredential" do
    association :organization
    token { "sk-ant-api03-#{SecureRandom.alphanumeric(40)}" }

    trait :oauth do
      token { "sk-ant-oat01-#{SecureRandom.alphanumeric(40)}" }
    end
  end
end
