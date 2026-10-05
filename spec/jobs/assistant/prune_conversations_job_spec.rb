# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::PruneConversationsJob do
  let(:cutoff_past) { (Assistant::Constants::RETENTION_DAYS + 1).days.ago }

  it "elimina le conversazioni oltre la retention (per ultima attività)" do
    old    = create(:assistant_conversation, last_message_at: cutoff_past)
    recent = create(:assistant_conversation, last_message_at: 1.day.ago)

    described_class.perform_now

    expect(Assistant::Conversation.exists?(old.id)).to be(false)
    expect(Assistant::Conversation.exists?(recent.id)).to be(true)
  end

  it "elimina le conversazioni vuote e vecchie (per data di creazione)" do
    old_empty = create(:assistant_conversation, last_message_at: nil, created_at: cutoff_past)

    described_class.perform_now
    expect(Assistant::Conversation.exists?(old_empty.id)).to be(false)
  end

  it "elimina a cascata i messaggi delle conversazioni potate" do
    old = create(:assistant_conversation, last_message_at: cutoff_past)
    create(:assistant_message, conversation: old)

    expect { described_class.perform_now }.to change(Assistant::Message, :count).by(-1)
  end
end
