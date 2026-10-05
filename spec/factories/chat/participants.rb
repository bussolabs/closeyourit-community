# frozen_string_literal: true

FactoryBot.define do
  factory :chat_participant, class: "Chat::Participant" do
    association :conversation, factory: :chat_conversation
    association :account

    # Integrità tenant: org denormalizzata dalla conversazione + account reso membro dell'org
    # (come :ticket_subscription).
    after(:build) do |participant|
      org = participant.conversation&.organization
      participant.organization ||= org
      next if org.blank? || participant.account.blank?

      participant.account.save! if participant.account.new_record?
      unless Connections::Membership.exists?(account_id: participant.account.id, organization_id: org.id)
        create(:membership, account: participant.account, organization: org)
      end
    end
  end
end
