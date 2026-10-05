# frozen_string_literal: true

require "rails_helper"

# CYEM-2 · Quando il servizio di embedding non risponde, ricerca semantica, collegamenti e
# deduplica smettono di funzionare in silenzio: nessun errore a schermo, nessun avviso. È già
# successo ed è durato un giorno e mezzo. Lo smoke esistente gira DENTRO il container e prova
# solo che il servizio parli a se stesso, quindi non può accorgersi che il guasto sta nel
# percorso fra chi chiede e chi risponde. Questo job chiama il servizio dalla stessa strada che
# usano le feature vere.
RSpec.describe Embeddings::CheckServiceHealthJob do
  let(:organization) { create(:organization) }

  # CYRA-875: the alert goes to the gods' organization only.
  before { create(:account, god: true).tap { |a| create(:membership, account: a, organization: organization) } }

  context "quando il servizio risponde" do
    before do
      allow(Embeddings::EmbedText).to receive(:call).and_return(
        Result.ok(Array.new(Ai::Constants::EMBEDDING_DIMENSIONS, 0.1))
      )
    end

    it "non logga e non avvisa nessuno" do
      allow(Rails.logger).to receive(:error)

      expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(Rails.logger).not_to have_received(:error)
    end
  end

  context "quando il servizio non risponde" do
    let(:failure) do
      Result.err(AppError.new("connessione rifiutata", code: "R502-AI-001", status: :bad_gateway))
    end

    before { allow(Embeddings::EmbedText).to receive(:call).and_return(failure) }

    it "logga il codice dell'errore, così il degrado silenzioso diventa visibile nei log" do
      allow(Rails.logger).to receive(:error)

      described_class.perform_now

      expect(Rails.logger).to have_received(:error).with(a_string_including("R502-AI-001"))
    end

    it "alerts the god's organization" do
      expect { described_class.perform_now }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "embedding_down", organization_id: organization.id))
    end

    it "usa la stessa strada delle feature vere: passa da EmbedText, non da un ping al servizio" do
      described_class.perform_now

      expect(Embeddings::EmbedText).to have_received(:call).with(hash_including(text: an_instance_of(String)))
    end
  end

  context "quando la funzione embeddings è spenta di proposito" do
    before do
      allow(Ai::Feature).to receive(:disabled?).with(:embeddings).and_return(true)
    end

    # Spegnere gli embedding è una scelta, non un guasto: svegliare qualcuno di notte per una
    # funzione disattivata di proposito è il modo più rapido per far ignorare gli avvisi veri.
    it "non avvisa nessuno" do
      expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end
end
