require "rails_helper"

RSpec.describe Ticketing::SummarizeComment do
  let(:max) { Ticketing::Constants::COMMENT_MAX_CHARS }
  let(:long_body) do
    "Fatto. Aggiunte le verifiche mancanti sui due controller dei file segreti, " \
      "i peggiori del progetto per rami non eseguiti. #{"Dettaglio tecnico. " * 80}"
  end

  def client_returning(summary)
    instance_double(Ai::Llm::Client, generate_content: { "summary" => summary })
  end

  let(:organization) { create(:organization) }

  def summarize(body: long_body, version: 2, client: client_returning("Riassunto breve."),
                organization: self.organization)
    described_class.call(body: body, report_version: version, organization: organization, client: client)
  end

  describe "riassunto" do
    it "ritorna il testo del modello col rimando al resoconto" do
      result = summarize(client: client_returning("Coperti i rami scoperti dei due controller."))

      expect(result).to be_ok
      expect(result.value).to eq("Coperti i rami scoperti dei due controller. (resoconto v2)")
    end

    it "non supera mai il tetto, nemmeno se il modello sfora" do
      result = summarize(client: client_returning("x" * 400))

      expect(result.value.length).to be <= max
      expect(result.value).to end_with("(resoconto v2)")
    end

    it "manda al modello il corpo da riassumere" do
      client = client_returning("Breve.")
      described_class.call(body: "Testo da riassumere.", report_version: 1, organization: organization, client: client)

      expect(client).to have_received(:generate_content) do |system:, contents:, **|
        expect(system).to include("240")
        expect(contents.to_s).to include("Testo da riassumere.")
      end
    end
  end

  describe "interruttore del god" do
    it "non chiama il modello se la compattazione è spenta" do
      Settings::Global.instance.update!(ai_comment_compaction_enabled: false)
      client = client_returning("Non deve arrivarci.")

      result = summarize(client: client)

      expect(result).to be_err
      expect(result.error.code).to eq("R503-AI-001")
      expect(client).not_to have_received(:generate_content)
    end
  end

  describe "degrado" do
    it "ritorna un errore, mai un'eccezione, se il modello fallisce" do
      client = instance_double(Ai::Llm::Client)
      allow(client).to receive(:generate_content)
        .and_raise(Ai::Llm::Client::Error.new("quota esaurita", code: "R429-LLM-001"))

      result = summarize(client: client)

      expect(result).to be_err
      expect(result.error.code).to eq("R429-LLM-001")
    end

    it "ritorna un errore se il modello risponde senza riassunto" do
      result = summarize(client: instance_double(Ai::Llm::Client, generate_content: { "summary" => "  " }))

      expect(result).to be_err
    end
  end

  describe "ripiego deterministico" do
    it "tronca il testo VERO sul confine di parola, senza inventare" do
      fallback = described_class.fallback(body: "Prima frase lunghissima " * 40, report_version: 3)

      expect(fallback.length).to be <= max
      expect(fallback).to end_with("(resoconto v3)")
      expect(fallback).to start_with("Prima frase")
    end

    it "lascia intatto un testo che ci sta già" do
      expect(described_class.fallback(body: "Corto.", report_version: 1)).to eq("Corto.")
    end
  end

  # CYRA-765 — il riassunto lo fa il server AI del sistema: senza configurazione si esce con un
  # errore leggibile, non con un 500.
  describe "server AI non configurato" do
    it "non chiama il modello e torna R502-LLM-002" do
      allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

      result = described_class.call(body: long_body, report_version: 1, organization: organization)

      expect(result).to be_err
      expect(result.error.code).to eq("R502-LLM-002")
    end
  end
end
