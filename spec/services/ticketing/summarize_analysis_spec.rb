require "rails_helper"

RSpec.describe Ticketing::SummarizeAnalysis do
  let(:max) { Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS }
  let(:name) { "analisi-tecnica-CYRA-176.md" }
  let(:long_body) do
    "Il problema era che il trace_id non veniva propagato al worker. " \
      "#{"Dettaglio dell'implementazione. " * 200}"
  end

  def client_returning(summary)
    instance_double(Ai::Llm::Client, generate_content: { "summary" => summary })
  end

  let(:organization) { create(:organization) }

  def summarize(body: long_body, client: client_returning("Spiegazione breve."), organization: self.organization)
    described_class.call(body: body, attachment_name: name, organization: organization, client: client)
  end

  describe "spiegazione" do
    it "ritorna il testo del modello col rimando all'allegato" do
      result = summarize(client: client_returning("Il trace_id ora viaggia col job."))

      expect(result).to be_ok
      expect(result.value).to eq("Il trace_id ora viaggia col job.\n\nDettaglio completo nell'allegato #{name}")
    end

    it "non supera mai il tetto del campo, nemmeno se il modello sfora" do
      result = summarize(client: client_returning("x" * (max + 500)))

      expect(result.value.length).to be <= max
      expect(result.value).to end_with(name)
    end

    it "manda al modello il testo da spiegare" do
      client = client_returning("Breve.")
      described_class.call(body: "Analisi da spiegare.", attachment_name: name, organization: organization, client: client)

      expect(client).to have_received(:generate_content) do |system:, contents:, **|
        expect(system).to include("1200")
        expect(contents.to_s).to include("Analisi da spiegare.")
      end
    end

    it "tronca il testo in ingresso invece di spedire tutto al modello" do
      client = client_returning("Breve.")
      described_class.call(body: "y" * 30_000, attachment_name: name, organization: organization, client: client)

      expect(client).to have_received(:generate_content) do |contents:, **|
        expect(contents.to_s.length).to be <= described_class::INPUT_CLAMP + 200
      end
    end
  end

  describe "interruttore del god" do
    it "non chiama il modello se la compattazione è spenta" do
      Settings::Global.instance.update!(ai_comment_compaction_enabled: false)
      client = client_returning("Non deve arrivarci.")

      expect(summarize(client: client)).to be_err
      expect(client).not_to have_received(:generate_content)
    end
  end

  describe "risposta vuota" do
    it "è un errore, non una scrittura vuota" do
      expect(summarize(client: client_returning("   "))).to be_err
    end
  end

  # CYRA-765 — la spiegazione la fa il server AI del sistema: chi legge sa cosa manca invece di
  # vedere un errore di gateway.
  describe "server AI non configurato" do
    it "non chiama il modello e torna R502-LLM-002" do
      allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

      result = described_class.call(body: long_body, attachment_name: name, organization: organization)

      expect(result).to be_err
      expect(result.error.code).to eq("R502-LLM-002")
    end

    it "senza client iniettato il service se lo costruisce da sé, senza chiedere niente all'organizzazione" do
      allow(Ai::Llm::Client).to receive(:new).and_return(client_returning("Spiegazione."))

      result = described_class.call(body: long_body, attachment_name: name, organization: organization)

      expect(result).to be_ok
      expect(Ai::Llm::Client).to have_received(:new).with(no_args)
    end
  end

  describe "ripiego senza AI" do
    it "tronca il testo vero e rimanda all'allegato" do
      text = described_class.fallback(body: long_body, attachment_name: name)

      expect(text.length).to be <= max
      expect(text).to start_with("Il problema era che il trace_id")
      expect(text).to end_with("Dettaglio completo nell'allegato #{name}")
    end

    it "lascia intatto un testo che ci sta già" do
      text = described_class.fallback(body: "Analisi corta.", attachment_name: name)

      expect(text).to eq("Analisi corta.\n\nDettaglio completo nell'allegato #{name}")
    end
  end
end
