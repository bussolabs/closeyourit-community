# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::StreamReplyJob do
  let(:conversation) { create(:assistant_conversation) }
  let(:message) { create(:assistant_message, :assistant_streaming, conversation: conversation) }

  # Il turno utente che precede la risposta (la history lo passa al server AI come contesto).
  before { create(:assistant_message, conversation: conversation, role: :user, content: "come apro un ticket?") }

  def stub_client(&behaviour)
    fake = instance_double(Ai::Llm::Client)
    allow(Ai::Llm::Client).to receive(:new).and_return(fake)
    allow(fake).to receive(:stream_chat, &behaviour)
    fake
  end

  describe "streaming riuscito" do
    it "accumula i delta e finalizza il messaggio come completo col testo intero" do
      stub_client { |**_kw, &block| block.call("Per "); block.call("aprire un ticket") }

      described_class.perform_now(message_id: message.id)

      expect(message.reload.status).to eq("complete")
      expect(message.content).to eq("Per aprire un ticket")
    end

    it "appende i chunk e poi rimpiazza la bolla finale sullo stream della conversazione" do
      stub_client { |**_kw, &block| block.call("ciao") }

      expect { described_class.perform_now(message_id: message.id) }
        .to have_broadcasted_to(Realtime::Streams.assistant_conversation(conversation)).at_least(:twice)
    end

    it "reidrata Current.account/organization e il locale utente durante il broadcast finale" do
      # Il job gira fuori dalla request: senza Current l'helper del catalogo torna vuoto (link non
      # cliccabili) e senza il locale utente le stringhe UI usano quello di default. Spio il rimpiazzo
      # finale e catturo il contesto attivo in quel momento.
      stub_client { |**_kw, &block| block.call("ok") }
      captured = {}
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) do |*_args, **_kwargs|
        captured = { account: Current.account, organization: Current.organization, locale: I18n.locale }
      end

      described_class.perform_now(message_id: message.id)

      expect(captured[:account]).to eq(conversation.account)
      expect(captured[:organization]).to eq(conversation.organization)
      expect(captured[:locale]).to eq(conversation.account.effective_locale.to_sym)
    end
  end

  describe "degrado" do
    it "su errore del provider marca il messaggio come fallito col codice errore, senza sollevare" do
      stub_client { |**_kw| raise Ai::Llm::Client::Error.new("boom", code: "R502-LLM-001") }

      expect { described_class.perform_now(message_id: message.id) }.not_to raise_error
      expect(message.reload.status).to eq("failed")
      expect(message.error_code).to eq("R502-LLM-001")
    end

    # Senza chiave o indirizzo il client solleva KeyError PRIMA della rete: è configurazione
    # mancante, non un guasto del fornitore, e la bolla si chiude dicendolo (R502-LLM-002).
    it "su server AI non configurato marca fallito senza sollevare" do
      allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError.new("AI_API_KEY vuota"))

      expect { described_class.perform_now(message_id: message.id) }.not_to raise_error
      expect(message.reload.status).to eq("failed")
      expect(message.error_code).to eq("R502-LLM-002")
    end

    it "marca fallito come risposta-non-prodotta (R502-LLM-004), non come guasto, se il server AI non produce testo" do
      stub_client { |**_kw| nil }

      described_class.perform_now(message_id: message.id)
      expect(message.reload.status).to eq("failed")
      expect(message.error_code).to eq("R502-LLM-004")
    end

    it "marca fallito senza sollevare se un componente inatteso solleva (es. catalogo/i18n)" do
      stub_client { |**_kw| nil }
      allow(Assistant::BuildCatalog).to receive(:call).and_raise(StandardError, "boom")

      expect { described_class.perform_now(message_id: message.id) }.not_to raise_error
      expect(message.reload.status).to eq("failed")
    end

    it "logga la causa reale dell'errore provider (non solo l'error_code) per renderlo visibile al monitoring" do
      allow(Rails.logger).to receive(:warn)
      stub_client { |**_kw| raise Ai::Llm::Client::Error.new("boom", code: "R502-LLM-002") }

      described_class.perform_now(message_id: message.id)

      expect(Rails.logger).to have_received(:warn).with(/R502-LLM-002/)
    end

    # CYRA-186: il server AI sovraccarico è l'unico errore del fornitore che rende l'assistente muto
    # per TUTTI e resta tale finché non si libera capacità (durò giorni, e se ne accorse una persona
    # provando la chat a mano). Non c'è modello di riserva: è un guasto, non l'inciampo di una
    # singola richiesta, e va distinto nel monitoring dai warn.
    it "logga a livello error il server AI non disponibile (R503), non a warn come gli altri guasti" do
      allow(Rails.logger).to receive(:error)
      allow(Rails.logger).to receive(:warn)
      stub_client { |**_kw| raise Ai::Llm::Client::Error.new("sovraccarico", code: "R503-LLM-001") }

      described_class.perform_now(message_id: message.id)

      expect(message.reload.error_code).to eq("R503-LLM-001")
      expect(Rails.logger).to have_received(:error).with(/R503-LLM-001/)
      expect(Rails.logger).not_to have_received(:warn).with(/R503-LLM-001/)
    end

    # L'AI la offre il sistema (CYRA-765): il client si costruisce da ENV, non dall'organizzazione
    # della conversazione — non esiste più una chiave per organizzazione da risolvere.
    it "costruisce il client dalla configurazione di sistema, senza chiave per organizzazione" do
      stub_client { |**_kw, &block| block.call("ciao") }

      described_class.perform_now(message_id: message.id)

      expect(Ai::Llm::Client).to have_received(:new).with(no_args)
    end
  end

  describe "idempotenza" do
    it "ignora un messaggio già completato (non richiama il server AI)" do
      done = create(:assistant_message, :assistant_reply, conversation: conversation)
      expect(Ai::Llm::Client).not_to receive(:new)

      described_class.perform_now(message_id: done.id)
    end

    it "non solleva se il messaggio non esiste più" do
      expect { described_class.perform_now(message_id: SecureRandom.uuid) }.not_to raise_error
    end
  end

  describe "concorrenza per conversazione" do
    it "deriva la chiave di concorrenza dal conversation_id: due messaggi della stessa conversazione la condividono" do
      other = create(:assistant_message, :assistant_streaming, conversation: conversation)

      expect(described_class.new(message_id: message.id).concurrency_key)
        .to eq(described_class.new(message_id: other.id).concurrency_key)
    end

    it "conversazioni diverse hanno chiavi di concorrenza diverse (restano parallele)" do
      other_message = create(:assistant_message, :assistant_streaming, conversation: create(:assistant_conversation))

      expect(described_class.new(message_id: message.id).concurrency_key)
        .not_to eq(described_class.new(message_id: other_message.id).concurrency_key)
    end
  end
end
