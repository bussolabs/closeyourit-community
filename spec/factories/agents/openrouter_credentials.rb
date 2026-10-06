# frozen_string_literal: true

FactoryBot.define do
  factory :agent_openrouter_credential, class: "Agents::OpenrouterCredential" do
    association :organization
    token { "sk-or-v1-#{SecureRandom.hex(32)}" }
  end
end
