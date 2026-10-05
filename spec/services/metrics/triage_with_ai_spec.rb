# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::TriageWithAi do
  let(:group) { create(:metric_group) }
  let(:client) { instance_double(Ai::Llm::Client) }

  # Con `response_schema` il client restituisce l'Hash gia parsato: niente involucro da spacchettare.
  def response_args(args) = args

  it "ritorna il verdetto di triage performance" do
    allow(client).to receive(:generate_content).and_return(response_args(
      "category" => "N+1", "severity" => "high", "root_cause" => "loop di query",
      "suggested_fix" => "use_includes", "suggested_action" => "promote",
      "confidence" => "high", "summary" => "Carica l'associazione con includes."
    ))

    result = described_class.call(group:, client:)

    expect(result).to be_ok
    triage = result.value
    expect(triage.category).to eq("N+1")
    expect(triage.suggested_fix).to eq("use_includes")
    expect(triage.suggested_action).to eq("promote")
    expect(triage.severity).to eq("high")
  end

  it "ripiega su valori sicuri su enum fuori vocabolario" do
    allow(client).to receive(:generate_content).and_return(response_args(
      "category" => "x", "severity" => "epica", "suggested_fix" => "magia",
      "suggested_action" => "explode", "confidence" => "boh", "summary" => "y"
    ))

    result = described_class.call(group:, client:)

    expect(result.value.suggested_fix).to eq("none")
    expect(result.value.suggested_action).to eq("none")
    expect(result.value.confidence).to eq("low")
    expect(result.value.severity).to be_nil
  end

  it "propaga il codice errore del gateway" do
    allow(client).to receive(:generate_content).and_raise(
      Ai::Llm::Client::Error.new("timeout", code: "R504-LLM-001", status: :gateway_timeout)
    )

    result = described_class.call(group:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R504-LLM-001")
  end

  it "include il subtype nel contesto per i performance issue" do
    perf = create(:metric_group, :performance_issue)
    captured = nil
    allow(client).to receive(:generate_content) do |**kwargs|
      captured = kwargs[:contents]
      response_args("category" => "x", "suggested_fix" => "none", "suggested_action" => "none",
                    "confidence" => "low", "summary" => "y")
    end

    result = described_class.call(group: perf, client:)

    expect(result).to be_ok
    expect(captured.first[:parts].first[:text]).to include("performance_issue / n_plus_one")
  end

  it "gestisce min/max nulli senza errore" do
    bare = create(:metric_group, duration_min_ms: nil, duration_max_ms: nil)
    allow(client).to receive(:generate_content).and_return(response_args(
      "category" => "x", "suggested_fix" => "none", "suggested_action" => "none",
      "confidence" => "low", "summary" => "y"
    ))

    result = described_class.call(group: bare, client:)

    expect(result).to be_ok
  end

  it "gestisce first/last_seen nulli (safe-nav &.iso8601 else)" do
    naked = create(:metric_group, first_seen_at: nil, last_seen_at: nil)
    allow(client).to receive(:generate_content).and_return(response_args(
      "category" => "x", "suggested_fix" => "none", "suggested_action" => "none",
      "confidence" => "low", "summary" => "y"
    ))

    result = described_class.call(group: naked, client:)

    expect(result).to be_ok
  end

  # CYRA-765 — anche il triage delle performance passa dal server AI del sistema.
  it "col server AI non configurato dice cosa manca invece di sollevare" do
    allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

    result = described_class.call(group:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-002")
    expect(result.error.status).to eq(:bad_gateway)
  end

  # Lo schema vincola la risposta a un oggetto; se il fornitore consegnasse altro, il triage non deve
  # inventarsi un verdetto vuoto — che l'umano leggerebbe come «l'AI non ha trovato niente».
  it "err R502-AI-003 se la risposta non è un oggetto" do
    allow(client).to receive(:generate_content).and_return([ "non un verdetto" ])

    result = described_class.call(group:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-AI-003")
  end
end
