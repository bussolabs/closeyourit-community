# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::Message, type: :model do
  describe "enum" do
    it "espone i ruoli user e assistant" do
      expect(described_class.roles.keys).to contain_exactly("user", "assistant")
    end

    it "exposes the streaming, complete, failed and transcribing statuses (CYRA-908)" do
      expect(described_class.statuses.keys).to contain_exactly("streaming", "complete", "failed", "transcribing")
    end
  end

  describe "isolamento tenant" do
    it "rifiuta un messaggio con organizzazione diversa da quella della conversazione" do
      conversation = create(:assistant_conversation)
      message = build(:assistant_message, conversation: conversation, organization: create(:organization))
      expect(message).not_to be_valid
    end
  end

  describe "presenza del contenuto" do
    it "richiede il contenuto per un messaggio dell'utente" do
      expect(build(:assistant_message, role: :user, status: :complete, content: nil)).not_to be_valid
    end

    it "richiede il contenuto per una risposta completata dell'assistente" do
      expect(build(:assistant_message, :assistant_reply, content: nil)).not_to be_valid
    end

    it "ammette il contenuto vuoto mentre l'assistente sta ancora scrivendo (streaming)" do
      expect(build(:assistant_message, :assistant_streaming)).to be_valid
    end

    it "ammette il contenuto vuoto su una risposta fallita" do
      expect(build(:assistant_message, :failed)).to be_valid
    end
  end

  describe ".chronological" do
    it "ordina i messaggi per data di creazione" do
      conversation = create(:assistant_conversation)
      primo = create(:assistant_message, conversation: conversation, created_at: 2.minutes.ago)
      secondo = create(:assistant_message, conversation: conversation, created_at: 1.minute.ago)
      expect(conversation.messages.chronological).to eq([ primo, secondo ])
    end
  end

  # CYRA-436 — l'utente deve capire se l'assistente ha avuto un problema momentaneo (riprova) o se non
  # ha capito la domanda (riformula). error_kind traduce l'error_code interno in questa distinzione.
  describe "#error_kind" do
    it "è nil quando il messaggio non è fallito" do
      expect(build(:assistant_message, :assistant_reply).error_kind).to be_nil
    end

    it "è :no_answer quando il servizio ha risposto ma non ha prodotto testo per la domanda" do
      expect(build(:assistant_message, :failed, error_code: "R502-LLM-004").error_kind).to eq(:no_answer)
    end

    it "è :unavailable per un problema momentaneo del servizio (timeout, rete, auth, rate-limit, sovraccarico)" do
      %w[R504-LLM-001 R502-LLM-001 R502-LLM-002 R502-LLM-003 R429-LLM-001 R503-LLM-001].each do |code|
        expect(build(:assistant_message, :failed, error_code: code).error_kind).to eq(:unavailable)
      end
    end

    it "è :unavailable anche per un codice sconosciuto (default prudente)" do
      expect(build(:assistant_message, :failed, error_code: "R500-BOH").error_kind).to eq(:unavailable)
    end
  end

  describe "voice (CYRA-908)" do
    let(:conversation) { create(:assistant_conversation) }

    def user_message(**attrs)
      conversation.messages.create!(organization: conversation.organization, role: :user, **attrs)
    end

    it "allows a transcribing message without text" do
      expect(user_message(status: :transcribing, content: nil)).to be_persisted
    end

    it "calls an empty transcription :not_heard" do
      message = user_message(status: :failed, error_code: Assistant::Constants::NOT_HEARD_CODE)
      expect(message.error_kind).to eq(:not_heard)
    end

    it "is typed unless marked as transcribed" do
      expect(user_message(status: :complete, content: "hi")).not_to be_transcribed
    end
  end
end
