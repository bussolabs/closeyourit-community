# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Feature do
  describe ".enabled?" do
    it "parte acceso: un'istanza che non ha mai toccato gli interruttori si comporta come prima" do
      (described_class::KEYS - [ :knowledge_review ]).each do |key|
        expect(described_class.enabled?(key)).to be(true), "atteso #{key} acceso di default"
      end
    end

    # CYRA-764 — l'unica che nasce spenta: il suo gate è fail-closed e senza la chiave nel vault
    # bloccherebbe ogni salvataggio di pagina. La accende il god quando la chiave c'è.
    it "il revisore knowledge parte spento" do
      expect(described_class.enabled?(:knowledge_review)).to be(false)
    end

    it "segue l'interruttore del god" do
      Settings::Global.instance.update!(ai_agent_gate_enabled: false)

      expect(described_class.enabled?(:agent_gate)).to be(false)
      expect(described_class.disabled?(:agent_gate)).to be(true)
    end

    it "spegne SOLO il servizio scelto" do
      Settings::Global.instance.update!(ai_agent_gate_enabled: false)

      expect(described_class.enabled?(:assistant_chat)).to be(true)
      expect(described_class.enabled?(:embeddings)).to be(true)
    end

    it "accetta la chiave come stringa" do
      expect(described_class.enabled?("triage")).to be(true)
    end

    it "solleva su un servizio sconosciuto invece di rispondere a caso" do
      expect { described_class.enabled?(:teleport) }.to raise_error(ArgumentError, /teleport/)
    end

    # Fail-open deliberato: un errore leggendo la CONFIGURAZIONE non deve spegnere l'AI del prodotto.
    it "assume acceso se gli interruttori sono illeggibili" do
      allow(Settings::Global).to receive(:instance).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect(described_class.enabled?(:triage)).to be(true)
    end
  end

  describe ".disabled_error" do
    it "porta codice, stato e un messaggio che nomina il servizio" do
      error = described_class.disabled_error(:agent_gate)

      expect(error).to be_a(AppError)
      expect(error.code).to eq("R503-AI-001")
      expect(error.status).to eq(:service_unavailable)
      expect(error.message).to include("agent eligibility gate")
    end

    it "parla la lingua dell'utente" do
      error = I18n.with_locale(:it) { described_class.disabled_error(:agent_gate) }

      expect(error.message).to include("gate di eleggibilità agenti")
    end

    it "ha una traduzione per ogni servizio, in entrambe le lingue" do
      %i[it en].each do |locale|
        I18n.with_locale(locale) do
          described_class::KEYS.each do |key|
            message = described_class.disabled_error(key).message
            expect(message).not_to include("translation missing"), "manca #{key} in #{locale}"
          end
        end
      end
    end
  end

  describe "contratto con Settings::Global" do
    it "ogni chiave ha la sua colonna" do
      described_class::KEYS.each do |key|
        expect(Settings::Global.column_names).to include("ai_#{key}_enabled")
      end
    end

    it "AI_SWITCH_COLUMNS copre esattamente le chiavi" do
      expect(Settings::Global::AI_SWITCH_COLUMNS.size).to eq(described_class::KEYS.size)
    end
  end

  it "has a voice switch, on by default and independent from the chat one (CYRA-908)" do
    expect(described_class.enabled?(:assistant_voice)).to be(true)

    Settings::Global.instance.update!(ai_assistant_voice_enabled: false)

    expect(described_class.disabled?(:assistant_voice)).to be(true)
    expect(described_class.enabled?(:assistant_chat)).to be(true)
  end
end
