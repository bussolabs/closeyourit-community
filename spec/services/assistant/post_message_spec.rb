# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::PostMessage do
  let(:conversation) { create(:assistant_conversation) }

  describe "con testo valido" do
    it "crea il messaggio dell'utente (completo) e la risposta dell'assistente (in streaming)" do
      expect { described_class.call(conversation: conversation, text: "come apro un ticket?") }
        .to change { conversation.messages.count }.by(2)

      expect(conversation.messages.chronological.pluck(:role)).to eq(%w[user assistant])
      assistant = conversation.messages.status_streaming.sole
      expect(assistant.content).to be_nil
    end

    it "aggiorna last_message_at e ricava un titolo dal primo messaggio" do
      described_class.call(conversation: conversation, text: "come apro un ticket?")
      expect(conversation.reload.last_message_at).to be_present
      expect(conversation.title).to be_present
    end

    context "when the tool loop is on" do
      it "enqueues the converse job with the scope frozen now and the page catalog" do
        expect { described_class.call(conversation: conversation, text: "my tickets?") }
          .to have_enqueued_job(Assistant::ConverseJob)
          .with(hash_including(with_catalog: true, scope_listed: true))
      end

      it "delays the job so the panel can subscribe to the stream first" do
        described_class.call(conversation: conversation, text: "ciao")
        job = ActiveJob::Base.queue_adapter.enqueued_jobs.find { |j| j[:job] == Assistant::ConverseJob }
        expect(job[:at]).to be_present
      end

      it "does not enqueue the streaming job" do
        expect { described_class.call(conversation: conversation, text: "ciao") }
          .not_to have_enqueued_job(Assistant::StreamReplyJob)
      end
    end

    context "when the tool loop is switched off" do
      before { Settings::Global.instance.update!(ai_assistant_tools_enabled: false) }

      it "keeps the streaming job" do
        expect { described_class.call(conversation: conversation, text: "ciao") }
          .to have_enqueued_job(Assistant::StreamReplyJob)
      end
    end

    it "ritorna Result.ok con la risposta dell'assistente" do
      result = described_class.call(conversation: conversation, text: "ciao")
      expect(result).to be_ok
      expect(result.value.role).to eq("assistant")
    end

    it "appende le bolle sullo stream della conversazione" do
      expect { described_class.call(conversation: conversation, text: "ciao") }
        .to have_broadcasted_to(Realtime::Streams.assistant_conversation(conversation)).at_least(:once)
    end

    it "tronca un testo eccessivamente lungo (protezione DB/costi)" do
      described_class.call(conversation: conversation, text: "a" * 10_000)
      user = conversation.messages.role_user.first
      expect(user.content.length).to be <= Assistant::Constants::MAX_MESSAGE_CHARS
    end
  end

  describe "con testo vuoto" do
    it "ritorna Result.err R422-ASSISTANT-001 senza creare messaggi" do
      result = nil
      expect { result = described_class.call(conversation: conversation, text: "   ") }
        .not_to change { conversation.messages.count }

      expect(result).to be_err
      expect(result.error.code).to eq("R422-ASSISTANT-001")
    end

    it "enqueues no reply job" do
      expect { described_class.call(conversation: conversation, text: "   ") }
        .not_to have_enqueued_job
    end
  end

  # L'assistente spento dal god è l'unico freno rimasto prima della coda: nessun messaggio nasce per
  # restare senza risposta, e nessun lavoro finisce in coda per fallire. Il gate «organizzazione
  # collegata» è sparito con le chiavi per organizzazione (CYRA-765).
  describe "con l'assistente spento dal god" do
    it "resta spento, e lo dice col codice del freno generale" do
      Settings::Global.instance.update!(ai_assistant_chat_enabled: false)

      result = nil
      expect { result = described_class.call(conversation: conversation, text: "come apro un ticket?") }
        .not_to change { conversation.messages.count }

      expect(result).to be_err
      expect(result.error.code).to eq(Ai::Feature::ERROR_CODE)
    end
  end

  describe "correction_of (CYRA-908)" do
    let(:org) { conversation.organization }
    let(:original) do
      conversation.messages.create!(organization: org, role: :user, status: :complete, content: "apri CYSL",
                                    transcribed: true)
    end
    let!(:stale) do
      original # the reply must come after the corrected message
      reply = conversation.messages.create!(organization: org, role: :assistant, status: :complete, content: "ok")
      create(:assistant_proposal, message: reply)
    end

    it "discards the pending cards of the replies after the corrected message" do
      described_class.call(conversation: conversation, text: "apri CYFL", correction_of: original.id)
      expect(stale.reload).to be_status_discarded
    end

    it "leaves the cards alone without a correction" do
      described_class.call(conversation: conversation, text: "apri CYFL")
      expect(stale.reload).to be_status_pending
    end

    it "ignores a correction pointing to another conversation" do
      other = create(:assistant_conversation)
      foreign = other.messages.create!(organization: other.organization, role: :user, status: :complete, content: "x")
      described_class.call(conversation: conversation, text: "apri CYFL", correction_of: foreign.id)
      expect(stale.reload).to be_status_pending
    end
  end
end
