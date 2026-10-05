# frozen_string_literal: true

FactoryBot.define do
  # Default: canale di progetto (forma valida più semplice — contextable nella stessa org, niente
  # direct_key). Trait :direct per i DM, :team per i canali di team.
  factory :chat_conversation, class: "Chat::Conversation" do
    association :organization
    kind { :project }
    contextable { association(:project, organization: organization) }

    trait :direct do
      kind { :direct }
      contextable { nil }
      sequence(:direct_key) { |n| Digest::SHA256.hexdigest("dm-#{n}") }
    end

    trait :team do
      kind { :team }
      contextable { association(:team, organization: organization) }
    end
  end
end
