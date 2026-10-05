# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::NotifyJob do
  it "invoca il dispatch delle notifiche per il messaggio" do
    message = create(:chat_message)
    expect(Chat::Notifications::Dispatch).to receive(:call).with(message: message)
    described_class.perform_now(message_id: message.id)
  end

  it "no-op se il messaggio non esiste (retry innocuo)" do
    expect(Chat::Notifications::Dispatch).not_to receive(:call)
    expect do
      described_class.perform_now(message_id: "00000000-0000-0000-0000-000000000000")
    end.not_to raise_error
  end

  it "un retry dopo un fan-out parziale non duplica le notifiche già consegnate (dedup)" do
    org = create(:organization)
    shared = create(:project, organization: org)
    accounts = Array.new(2) do
      account = create(:account)
      create(:membership, account: account, organization: org, role: :member)
      create(:project_membership, account: account, project: shared)
      account
    end
    conversation = Chat::Conversations::FindOrCreateDirect.call(
      organization: org, account_a: accounts.first, account_b: accounts.last
    ).value
    message = conversation.messages.create!(body: "retry", author: accounts.first, organization_id: org.id)

    # Primo giro: consegna reale. Secondo giro (il retry di retry_on): la dedup_key blocca i doppioni.
    described_class.perform_now(message_id: message.id)
    expect { described_class.perform_now(message_id: message.id) }
      .not_to change { Alerting::Notification.where(account_id: accounts.last.id).count }
  end
end
