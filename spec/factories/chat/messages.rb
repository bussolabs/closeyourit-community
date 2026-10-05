# frozen_string_literal: true

FactoryBot.define do
  factory :chat_message, class: "Chat::Message" do
    association :conversation, factory: :chat_conversation
    body { Faker::Lorem.sentence }

    # Integrità tenant: org denormalizzata dalla conversazione + autore membro dell'org.
    after(:build) do |message|
      org = message.conversation&.organization
      message.organization ||= org
      next if org.blank?

      message.author ||= build(:account)
      message.author.save! if message.author.new_record?
      unless Connections::Membership.exists?(account_id: message.author.id, organization_id: org.id)
        create(:membership, account: message.author, organization: org)
      end
    end
  end
end
