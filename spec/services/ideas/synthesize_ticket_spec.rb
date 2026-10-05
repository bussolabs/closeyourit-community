# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::SynthesizeTicket do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) do
    create(:idea, organization:, project:, title: "Dark mode", problem: "Vorrei un tema scuro",
                  solution: "Tema scuro di sistema", stakeholders: [ "Team Mobile" ])
  end
  let(:client) { instance_double(Ai::Llm::Client) }

  # generate_content(response_schema:) ritorna già l'Hash parsato (chiavi stringa).
  def draft_response(args)
    args
  end

  it "ritorna la bozza (title + description) dallo structured output" do
    allow(client).to receive(:generate_content).and_return(draft_response(
      "title" => "Tema scuro per la dashboard", "description" => "## Perché\nRichiesto dal team."
    ))

    result = described_class.call(idea:, client:)

    expect(result).to be_ok
    expect(result.value.title).to eq("Tema scuro per la dashboard")
    expect(result.value.description).to include("Richiesto dal team")
  end

  it "il prompt include idea (problema/soluzione/stakeholder/case) e commenti, clampati" do
    idea.cases.create!(title: "Uso notturno", description: "Chi lavora di notte")
    idea.cases.create!(title: "Senza dettagli", description: "")
    create(:idea_comment, idea:, organization:, body: "Serve anche su mobile", created_at: 2.hours.ago)
    create(:idea_comment, :long, idea:, organization:, created_at: 1.hour.ago)

    captured = nil
    allow(client).to receive(:generate_content) do |contents:, **|
      captured = contents
      draft_response("title" => "t", "description" => "d")
    end

    described_class.call(idea:, client:)

    user_content = captured.last[:parts].first[:text]
    expect(user_content).to include("Dark mode", "Vorrei un tema scuro", "Tema scuro di sistema",
                                    "Team Mobile", "Uso notturno", "Serve anche su mobile")
    # CYRA-371 — il clamp regge un intervento argomentato (che ora è il caso normale) ma non un
    # commento monstre: il primo passa, il secondo viene tagliato a COMMENT_CLAMP.
    expect(user_content).to include("x" * 1_000)
    expect(user_content).not_to include("x" * (described_class::COMMENT_CLAMP + 100))
  end

  it "idea minimale (solo problema) → prompt senza righe soluzione/stakeholder/case" do
    minimal = create(:idea, organization:, project:, title: "Minimale",
                            problem: "Solo il problema", solution: "", stakeholders: [])

    captured = nil
    allow(client).to receive(:generate_content) do |contents:, **|
      captured = contents
      draft_response("title" => "t", "description" => "d")
    end

    described_class.call(idea: minimal, client:)

    user_content = captured.last[:parts].first[:text]
    expect(user_content).to include("Solo il problema", "Nessun commento del team.")
    expect(user_content).not_to include("Soluzione proposta", "Stakeholder", "Case (esempi")
  end

  it "title mancante → fallback sul titolo dell'idea" do
    allow(client).to receive(:generate_content).and_return(draft_response("title" => "", "description" => "Testo"))

    result = described_class.call(idea:, client:)

    expect(result).to be_ok
    expect(result.value.title).to eq("Dark mode")
  end

  it "description oltre il tetto del ticket → troncata (la bozza dev'essere salvabile)" do
    lunga = "x" * (Ticketing::Constants::DESCRIPTION_MAX_CHARS + 500)
    allow(client).to receive(:generate_content).and_return(draft_response("title" => "T", "description" => lunga))

    result = described_class.call(idea:, client:)

    expect(result).to be_ok
    expect(result.value.description.length).to eq(Ticketing::Constants::DESCRIPTION_MAX_CHARS)
  end

  it "description vuota → R502-AI-003 (bozza inutilizzabile)" do
    allow(client).to receive(:generate_content).and_return(draft_response("title" => "T", "description" => "  "))

    result = described_class.call(idea:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-AI-003")
  end

  it "output illeggibile dal provider (JSON non valido) → propaga il codice del client" do
    allow(client).to receive(:generate_content)
      .and_raise(Ai::Llm::Client::Error.new("JSON non valido", code: "R502-LLM-005"))

    result = described_class.call(idea:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-005")
  end

  it "errore del provider → propaga codice e status del client" do
    allow(client).to receive(:generate_content)
      .and_raise(Ai::Llm::Client::Error.new("provider giù", code: "R502-LLM-001", status: :bad_gateway))

    result = described_class.call(idea:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-001")
  end

  # CYRA-765 — la sintesi la fa il server AI del sistema, non un servizio collegato dall'organizzazione.
  describe "il server AI non configurato" do
    it "non chiama il modello e torna R502-LLM-002" do
      allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

      result = described_class.call(idea:)

      expect(result).to be_err
      expect(result.error.code).to eq("R502-LLM-002")
      expect(result.error.status).to eq(:bad_gateway)
    end

    it "senza client iniettato se lo costruisce da sé, senza chiedere niente all'organizzazione" do
      allow(Ai::Llm::Client).to receive(:new).and_return(client)
      allow(client).to receive(:generate_content).and_return("title" => "T", "description" => "D")

      described_class.call(idea:)

      expect(Ai::Llm::Client).to have_received(:new).with(no_args)
    end
  end

  # CYRA-845 — monetizzazione, rischi e idee collegate entrano nel prompt: la conversione non li perde.
  it "monetizzazione, rischi e idee collegate → nel prompt per titolo" do
    idea.update!(monetization: "Boost a pagamento", risks: "Serve moderazione")
    base = create(:idea, organization:, project:, title: "Idea madre")
    create(:idea_link, :evolution, source: idea, target: base)
    cousin = create(:idea, organization:, project:, title: "Idea cugina")
    create(:idea_link, source: cousin, target: idea)

    captured = nil
    allow(client).to receive(:generate_content) do |contents:, **|
      captured = contents
      draft_response("title" => "t", "description" => "d")
    end

    described_class.call(idea:, client:)

    user_content = captured.last[:parts].first[:text]
    expect(user_content).to include("Monetizzazione:", "Boost a pagamento", "Rischi e vincoli:", "Serve moderazione",
                                    "Evolve l'idea: Idea madre", "Idea collegata: Idea cugina")
  end
end
