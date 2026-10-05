# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::TriageWithAi do
  let(:group) { create(:error_group) }
  let(:client) { instance_double(Ai::Llm::Client) }

  # Con `response_schema` il client restituisce l'Hash gia parsato: niente involucro da spacchettare.
  def response_args(args) = args

  it "ritorna il verdetto di triage" do
    allow(client).to receive(:generate_content).and_return(response_args(
      "category" => "NULL dereference", "severity_suggested" => "error",
      "root_cause" => "widget senza dato", "suggested_action" => "promote",
      "confidence" => "high", "summary" => "Da promuovere a ticket."
    ))

    result = described_class.call(group:, client:)

    expect(result).to be_ok
    triage = result.value
    expect(triage.category).to eq("NULL dereference")
    expect(triage.severity_suggested).to eq("error")
    expect(triage.suggested_action).to eq("promote")
    expect(triage.confidence).to eq("high")
    expect(triage.summary).to eq("Da promuovere a ticket.")
  end

  it "ripiega su valori sicuri quando azione/confidenza/severità non sono nell'enum" do
    allow(client).to receive(:generate_content).and_return(response_args(
      "category" => "x", "severity_suggested" => "marziano",
      "suggested_action" => "delete", "confidence" => "altissima", "summary" => "y"
    ))

    result = described_class.call(group:, client:)

    expect(result).to be_ok
    expect(result.value.suggested_action).to eq("none")
    expect(result.value.confidence).to eq("low")
    expect(result.value.severity_suggested).to be_nil
  end

  it "propaga il codice errore del gateway su Client::Error" do
    allow(client).to receive(:generate_content).and_raise(
      Ai::Llm::Client::Error.new("timeout", code: "R504-LLM-001", status: :gateway_timeout)
    )

    result = described_class.call(group:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R504-LLM-001")
    expect(result.error.status).to eq(:gateway_timeout)
  end

  # Lo schema vincola la risposta a un oggetto; se il fornitore consegnasse altro, il triage non deve
  # inventarsi un verdetto vuoto — che l'umano leggerebbe come «l'AI non ha trovato niente».
  it "ritorna err R502-AI-003 se la risposta non è un oggetto" do
    allow(client).to receive(:generate_content).and_return([ "non un verdetto" ])

    result = described_class.call(group:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-AI-003")
  end

  # CYRA-765 — il triage lo fa il server AI del sistema: senza la sua configurazione l'esito è un
  # errore leggibile, non un 500.
  it "col server AI non configurato dice cosa manca invece di sollevare" do
    allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

    result = described_class.call(group:)

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

  # Senza client iniettato la chiamata esce davvero sul wire del server AI: chiave e indirizzo
  # vengono da ENV, non da una credenziale dell'organizzazione.
  it "senza client iniettato chiama il server AI con la chiave di sistema" do
    verdict = { "category" => "x", "suggested_action" => "none", "confidence" => "low", "summary" => "y" }
    stub_request(:post, "#{ENV.fetch('AI_BASE_URL')}/chat/completions")
      .with(headers: { "Authorization" => "Bearer #{ENV.fetch('AI_API_KEY')}" })
      .to_return(status: 200, body: sse_completion(verdict.to_json))

    expect(described_class.call(group:)).to be_ok
  end

  it "inserisce ambiente e stacktrace reale (forma Sentry {frames:...}) nel contesto inviato all'AI" do
    create(:error_event, group:, project: group.project, environment: "production",
           stacktrace: { "frames" => [ { "filename" => "app/x.rb", "lineno" => 9, "function" => "call" }, "frame-non-hash" ] })
    captured = nil
    allow(client).to receive(:generate_content) do |**kwargs|
      captured = kwargs[:contents]
      response_args("category" => "x", "suggested_action" => "none", "confidence" => "low", "summary" => "y")
    end

    result = described_class.call(group:, client:)

    expect(result).to be_ok
    user_content = captured.first[:parts].first[:text]
    expect(user_content).to include("Ambiente: production")
    expect(user_content).to include("app/x.rb:9 in call")
    expect(user_content).to include("frame-non-hash")
  end

  it "passa per primi i frame più vicini al crash (nell'ordine Sentry il crash è l'ultimo frame)" do
    create(:error_event, group:, project: group.project,
           stacktrace: { "frames" => [
             { "filename" => "lib/lontano.rb", "lineno" => 1, "function" => "boot", "in_app" => false },
             { "filename" => "app/models/widget.rb", "lineno" => 42, "function" => "render", "in_app" => true }
           ] })
    captured = nil
    allow(client).to receive(:generate_content) do |**kwargs|
      captured = kwargs[:contents]
      response_args("category" => "x", "suggested_action" => "none", "confidence" => "low", "summary" => "y")
    end

    result = described_class.call(group:, client:)

    expect(result).to be_ok
    user_content = captured.first[:parts].first[:text]
    expect(user_content).to include("app/models/widget.rb:42 in render")
    expect(user_content.index("app/models/widget.rb:42")).to be < user_content.index("lib/lontano.rb:1")
  end

  it "gestisce l'evento senza ambiente né stacktrace (frame vuoti → n/d)" do
    create(:error_event, group:, project: group.project, environment: nil, stacktrace: {})
    captured = nil
    allow(client).to receive(:generate_content) do |**kwargs|
      captured = kwargs[:contents]
      response_args("category" => "x", "suggested_action" => "none", "confidence" => "low", "summary" => "y")
    end

    result = described_class.call(group:, client:)

    expect(result).to be_ok
    expect(captured.first[:parts].first[:text]).to include("n/d")
  end

  it "gestisce un gruppo senza first/last_seen (safe-nav &.iso8601 else)" do
    naked = create(:error_group, first_seen_at: nil, last_seen_at: nil)
    allow(client).to receive(:generate_content).and_return(response_args(
      "category" => "x", "suggested_action" => "none", "confidence" => "low", "summary" => "y"
    ))

    result = described_class.call(group: naked, client:)

    expect(result).to be_ok
  end
end
