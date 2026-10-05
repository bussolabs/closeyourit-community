# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::Message, type: :model do
  it "la factory è valida" do
    expect(build(:chat_message)).to be_valid
  end

  describe "contenuto minimo" do
    it "è invalido senza testo né allegati" do
      message = build(:chat_message, body: nil)
      expect(message).to be_invalid
      expect(message.errors[:base]).to be_present
    end

    it "è valido con solo testo" do
      expect(build(:chat_message, body: "ciao")).to be_valid
    end

    it "è valido con solo allegato e body nil (messaggio-solo-file)" do
      message = build(:chat_message, body: nil)
      message.files.attach(io: StringIO.new("img"), filename: "shot.png", content_type: "image/png")
      expect(message).to be_valid
    end

    it "normalizza il body vuoto a nil" do
      message = build(:chat_message, body: "   ")
      expect(message.body).to be_nil
      expect(message).to be_invalid # blank dopo strip → nessun contenuto
    end

    it "normalizza la stringa vuota a nil (caso distinto dagli spazi)" do
      message = build(:chat_message, body: "")
      expect(message.body).to be_nil
      expect(message).to be_invalid
    end

    it "strippa gli spazi attorno al contenuto reale" do
      message = build(:chat_message, body: "  ciao  ")
      expect(message.body).to eq("ciao")
      expect(message).to be_valid
    end
  end

  describe "dependent alla destroy" do
    it "porta via i riferimenti del messaggio" do
      reference = create(:chat_message_reference)
      expect { reference.message.destroy! }.to change(Chat::MessageReference, :count).by(-1)
    end
  end

  describe "integrità tenant" do
    it "rifiuta un'org diversa da quella della conversazione" do
      message = build(:chat_message)
      message.organization = create(:organization)
      expect(message).to be_invalid
      expect(message.errors[:organization]).to be_present
    end

    it "rifiuta un autore non membro dell'org (anti-BOLA)" do
      conversation = create(:chat_conversation, :direct)
      outsider = create(:account) # nessuna membership nell'org della conversazione
      # .new diretto: evito l'after(:build) della factory che iscriverebbe l'autore all'org.
      message = described_class.new(conversation: conversation, organization: conversation.organization,
                                    author: outsider, body: "ciao")
      expect(message).to be_invalid
      expect(message.errors[:author]).to be_present
    end

    it "consente autore nil (account cancellato)" do
      message = build(:chat_message)
      message.author = nil
      expect(message).to be_valid
    end
  end

  describe "soft delete" do
    it "soft_delete! imposta deleted_at e la kept scope lo esclude" do
      message = create(:chat_message)
      message.soft_delete!
      expect(message.deleted?).to be(true)
      expect(described_class.kept).not_to include(message)
    end

    it "un messaggio soft-deleted resta valido anche senza contenuto" do
      message = create(:chat_message)
      message.body = nil
      message.deleted_at = Time.current
      expect(message).to be_valid
    end
  end

  describe "ordinamento" do
    it "chronological ordina per created_at poi id" do
      conversation = create(:chat_conversation, :direct)
      account = create(:account)
      create(:membership, account: account, organization: conversation.organization)
      older = create(:chat_message, conversation: conversation, author: account, created_at: 2.minutes.ago)
      newer = create(:chat_message, conversation: conversation, author: account, created_at: 1.minute.ago)

      expect(conversation.messages.chronological.to_a).to eq([ older, newer ])
    end
  end
end
