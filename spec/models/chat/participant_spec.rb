# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::Participant, type: :model do
  it "la factory è valida" do
    expect(build(:chat_participant)).to be_valid
  end

  describe "unicità" do
    it "un account non può partecipare due volte alla stessa conversazione" do
      first = create(:chat_participant)
      dup = build(:chat_participant, conversation: first.conversation, account: first.account)
      expect(dup).to be_invalid
    end
  end

  describe "integrità tenant" do
    it "rifiuta un'org diversa da quella della conversazione" do
      participant = build(:chat_participant)
      participant.organization = create(:organization)
      expect(participant).to be_invalid
      expect(participant.errors[:organization]).to be_present
    end

    it "rifiuta un account non membro dell'org (anti-BOLA)" do
      conversation = create(:chat_conversation, :direct)
      outsider = create(:account) # nessuna membership nell'org della conversazione
      # .new diretto: evito l'after(:build) della factory che iscriverebbe l'account all'org.
      participant = described_class.new(conversation: conversation, account: outsider,
                                        organization: conversation.organization)
      expect(participant).to be_invalid
      expect(participant.errors[:account]).to be_present
    end
  end

  it "senza account non aggiunge l'errore not_member (guard esce presto)" do
    conversation = create(:chat_conversation, :direct)
    participant = described_class.new(conversation: conversation, organization: conversation.organization)
    participant.valid?
    expect(participant.errors[:account]).not_to include(I18n.t("activerecord.errors.messages.not_member", default: "not_member"))
  end

  describe ".ensure_for" do
    it "è idempotente: due chiamate → una sola riga" do
      conversation = create(:chat_conversation, :direct)
      account = create(:account)
      create(:membership, account: account, organization: conversation.organization)

      first = described_class.ensure_for(conversation: conversation, account: account)
      second = described_class.ensure_for(conversation: conversation, account: account)

      expect(second.id).to eq(first.id)
      expect(conversation.participants.where(account_id: account.id).count).to eq(1)
    end
  end

  describe "#mark_read! / #muted?" do
    it "mark_read! imposta last_read_at" do
      participant = create(:chat_participant)
      freeze_time do
        participant.mark_read!
        expect(participant.last_read_at).to eq(Time.current)
      end
    end

    it "muted? riflette muted_at" do
      expect(build(:chat_participant, muted_at: nil).muted?).to be(false)
      expect(build(:chat_participant, muted_at: Time.current).muted?).to be(true)
    end
  end
end
