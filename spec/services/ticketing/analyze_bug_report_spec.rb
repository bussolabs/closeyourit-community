# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::AnalyzeBugReport do
  let(:project) { build_stubbed(:project, name: "Acme") }
  let(:client) { instance_double(Ai::Llm::Client) }

  # Con `response_schema` il client restituisce l'Hash già parsato: le forme intermedie del vecchio
  # gateway (tool_calls, content JSON, code fence) non esistono più — le provava l'estrattore, che
  # con lo schema nativo è sparito (CYRA-594).
  def analysis(args)
    allow(client).to receive(:generate_content).and_return(args)
  end

  it "ritorna un'analisi completa con uno scenario a 4 campi e nessuna domanda" do
    analysis(
      "complete" => true,
      "scenarios" => [ { "step_given" => "G", "step_when" => "W", "step_then" => "T", "step_expected" => "E" } ],
      "questions" => []
    )

    result = described_class.call(project:, text: "Su Safari il checkout non parte", client:)

    expect(result).to be_ok
    value = result.value
    expect(value.complete).to be(true)
    scenario = value.scenarios.first
    expect([ scenario[:step_given], scenario[:step_when], scenario[:step_then], scenario[:step_expected] ]).to eq(%w[G W T E])
    expect(value.questions).to be_empty
  end

  it "ricostruisce più scenari e l'analisi tecnica" do
    analysis(
      "complete" => true,
      "scenarios" => [
        { "step_given" => "G1", "step_when" => "W1", "step_then" => "T1", "step_expected" => "E1" },
        { "title" => "Errore", "step_given" => "G2", "step_when" => "W2", "step_then" => "T2", "step_expected" => "E2" }
      ],
      "technical_analysis" => "stack trace X", "questions" => []
    )

    value = described_class.call(project:, text: "x", client:).value
    expect(value.scenarios.size).to eq(2)
    expect(value.technical_analysis).to eq("stack trace X")
    expect(value.complete).to be(true)
  end

  it "tronca l'analisi tecnica oltre il tetto (il form pre-compilato dev'essere salvabile)" do
    analysis(
      "complete" => true,
      "scenarios" => [ { "step_given" => "G", "step_when" => "W", "step_then" => "T", "step_expected" => "E" } ],
      "technical_analysis" => "z" * (Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS + 500),
      "questions" => []
    )

    value = described_class.call(project:, text: "x", client:).value

    expect(value.technical_analysis.length).to eq(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
  end

  it "ritorna incompleta con domande quando mancano informazioni" do
    analysis("complete" => false, "questions" => [ "Quale browser usi?", "Cosa ti aspettavi succedesse?" ])

    result = described_class.call(project:, text: "non funziona", client:)

    expect(result).to be_ok
    expect(result.value.complete).to be(false)
    expect(result.value.questions).to contain_exactly("Quale browser usi?", "Cosa ti aspettavi succedesse?")
  end

  it "declassa a incompleta se nessuno scenario ha tutti e 4 i campi nonostante complete=true" do
    analysis(
      "complete" => true,
      "scenarios" => [ { "step_given" => "G", "step_when" => "", "step_then" => "T", "step_expected" => "E" } ],
      "questions" => []
    )

    result = described_class.call(project:, text: "x", client:)

    expect(result.value.complete).to be(false)
  end

  it "usa il modello pieno: l'analisi la rilegge chi ha scritto la segnalazione" do
    expect(client).to receive(:generate_content)
      .with(hash_including(model: Ai::Llm::Constants::MODEL))
      .and_return({ "complete" => false, "questions" => [ "Dettagli?" ] })

    described_class.call(project:, text: "x", client:)
  end

  it "propaga il codice errore del fornitore su Client::Error" do
    allow(client).to receive(:generate_content).and_raise(
      Ai::Llm::Client::Error.new("timeout", code: "R504-LLM-001", status: :gateway_timeout)
    )

    result = described_class.call(project:, text: "x", client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R504-LLM-001")
    expect(result.error.status).to eq(:gateway_timeout)
  end

  # Lo schema vincola la risposta a un oggetto, ma se il fornitore consegnasse altro il service non
  # deve inventarsi un'analisi vuota: meglio dire che non si è capito.
  it "risposta che non è un oggetto → err R502-AI-003" do
    analysis([ 42 ])

    result = described_class.call(project:, text: "x", client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-AI-003")
  end

  it "rifiuta il testo vuoto con R422 senza chiamare il fornitore" do
    expect(client).not_to receive(:generate_content)

    result = described_class.call(project:, text: "   ", client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-003")
  end

  # CYRA-765 — l'analisi la fa il server AI del sistema: chiave e indirizzo vengono da ENV, non da
  # una credenziale dell'organizzazione.
  describe "il server AI" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }

    it "non configurato → dice cosa manca invece di sollevare" do
      allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

      result = described_class.call(project:, text: "il checkout non parte")

      expect(result).to be_err
      expect(result.error.code).to eq("R502-LLM-002")
      expect(result.error.status).to eq(:bad_gateway)
    end

    # Un turno solo di streaming (CYRA-766: generate_content legge SSE anche quando chi la chiama la
    # vede sincrona).
    def sse_completion(text)
      [ { choices: [ { delta: { content: text }, finish_reason: nil } ] },
        { choices: [ { delta: {}, finish_reason: "stop" } ] } ].map { |c| "data: #{c.to_json}\n\n" }.join + "data: [DONE]\n\n"
    end

    it "senza client iniettato chiama il server AI con la chiave di sistema" do
      args = { complete: true,
               scenarios: [ { step_given: "G", step_when: "W", step_then: "T", step_expected: "E" } ],
               questions: [] }
      stub_request(:post, "#{ENV.fetch('AI_BASE_URL')}/chat/completions")
        .with(headers: { "Authorization" => "Bearer #{ENV.fetch('AI_API_KEY')}" })
        .to_return(status: 200, body: sse_completion(args.to_json))

      expect(described_class.call(project:, text: "il checkout non parte")).to be_ok
    end
  end
end
