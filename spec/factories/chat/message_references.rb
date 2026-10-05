# frozen_string_literal: true

FactoryBot.define do
  factory :chat_message_reference, class: "Chat::MessageReference" do
    association :message, factory: :chat_message
    # Default: tagga un progetto nella stessa org del messaggio.
    referable { association(:project, organization: message.organization) }

    after(:build) do |reference|
      reference.organization ||= reference.message&.organization
    end
  end
end
