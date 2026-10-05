# frozen_string_literal: true

require "rails_helper"

# Riscrive un'analisi tecnica già scritta nella forma a etichette (CYRA-266). Su 426 analisi in
# produzione 423 sono muri di prosa: la regola di knowledge-base/global/closeyourit-writing.md è
# arrivata dopo, e vale solo per il testo nuovo.
#
# La differenza che conta rispetto ai due service gemelli (SummarizeComment, SummarizeAnalysis):
# **qui non esiste un ripiego**. Là il testo integrale era già al sicuro altrove — in una versione
# del resoconto, in un allegato — e troncare era meglio di niente. Qui si riscrive l'UNICA copia di
# un testo che è già leggibile: se il modello tace, la cosa giusta è non toccare niente.
RSpec.describe Ticketing::RelabelAnalysis do
  let(:max) { Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS }
  let(:plain) do
    "Il contatore diventava ambra all'80% del tetto, quindi a 1200 su 1500. " \
      "Ho aggiunto una costante col bersaglio e un valore esplicito nello Stimulus."
  end

  def client_returning(text)
    instance_double(Ai::Llm::Client, generate_content: { "analysis" => text })
  end

  let(:organization) { create(:organization) }

  def relabel(body: plain, client: client_returning("**Approccio:** una costante e un valore nello Stimulus."))
    described_class.call(body: body, organization: organization, client: client)
  end

  describe "la riscrittura" do
    it "ritorna il testo del modello" do
      result = relabel(client: client_returning("**Approccio:** costante nuova.\n\n**Rischi:** nessuno."))

      expect(result).to be_ok
      expect(result.value).to eq("**Approccio:** costante nuova.\n\n**Rischi:** nessuno.")
    end

    it "manda al modello il testo da riscrivere e le etichette attese" do
      client = client_returning("**Approccio:** breve.")
      described_class.call(body: "Analisi da rietichettare.", organization: organization, client: client)

      expect(client).to have_received(:generate_content) do |system:, contents:, **|
        expect(system).to include("Approccio")
        expect(system).to include("Rischi")
        expect(contents.to_s).to include("Analisi da rietichettare.")
      end
    end

    it "non supera mai il tetto del campo, nemmeno se il modello sfora" do
      result = relabel(client: client_returning("**Approccio:** #{"x" * (max + 500)}"))

      expect(result.value.length).to be <= max
    end
  end

  describe "quando non c'è niente da fare" do
    # Idempotenza a monte del modello: un'analisi già a etichette non si manda nemmeno, così un
    # rilancio del rake non spende 423 chiamate per riscrivere ciò che ha appena scritto.
    it "non chiama il modello se il testo ha già le etichette" do
      client = client_returning("non dovrebbe servire")
      result = described_class.call(body: "**Approccio:** già a posto.\n\n**Rischi:** nessuno.", organization: organization, client: client)

      expect(result).to be_ok
      expect(result.value).to be_nil
      expect(client).not_to have_received(:generate_content)
    end

    it "non chiama il modello su un testo vuoto" do
      client = client_returning("non dovrebbe servire")
      result = described_class.call(body: "   ", organization: organization, client: client)

      expect(result.value).to be_nil
      expect(client).not_to have_received(:generate_content)
    end
  end

  describe "quando il modello non collabora" do
    # NIENTE ripiego al troncamento, al contrario dei due service gemelli: qui l'originale è l'unica
    # copia, ed è già leggibile. Un errore lascia il campo intatto e il ticket non marcato, quindi il
    # rilancio lo riprende.
    it "torna in errore se la risposta è vuota" do
      result = relabel(client: client_returning("  "))

      expect(result).to be_err
      expect(result.error.code).to eq("R502-RELABEL-001")
    end

    it "torna in errore se il modello riscrive senza etichette" do
      result = relabel(client: client_returning("Un testo riscritto ma senza nessuna etichetta."))

      expect(result).to be_err
      expect(result.error.code).to eq("R502-RELABEL-002")
    end

    it "propaga l'errore del client" do
      client = instance_double(Ai::Llm::Client)
      allow(client).to receive(:generate_content).and_raise(Ai::Llm::Client::Error.new("boom", code: "R502-AI-009"))

      expect(relabel(client: client)).to be_err
    end
  end

  describe "il freno d'emergenza" do
    it "si ferma prima di spendere una chiamata quando il servizio è spento" do
      allow(Ai::Feature).to receive(:disabled?).with(:analysis_relabel).and_return(true)
      client = client_returning("non dovrebbe servire")

      result = described_class.call(body: plain, organization: organization, client: client)

      expect(result).to be_err
      expect(result.error.code).to eq(Ai::Feature::ERROR_CODE)
      expect(client).not_to have_received(:generate_content)
    end
  end

  # CYRA-765 — l'AI la offre il sistema: quel che può mancare non è più la chiave di
  # un'organizzazione ma la configurazione del server AI. Il testo NON viene toccato lo stesso.
  describe "server AI non configurato" do
    it "non chiama il modello e torna un errore pulito, mai un 500" do
      allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

      result = described_class.call(body: plain, organization: organization)

      expect(result).to be_err
      expect(result.error.code).to eq("R502-LLM-002")
    end

    it "il freno del god resta sopra: spento vuol dire spento anche col server AI configurato" do
      allow(Ai::Feature).to receive(:disabled?).with(:analysis_relabel).and_return(true)

      result = described_class.call(body: plain, organization: organization)

      expect(result.error.code).to eq(Ai::Feature::ERROR_CODE)
    end
  end
end
