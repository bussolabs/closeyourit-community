# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::AskPages do
  let(:embed_client) { instance_double(Ai::Embedding::Client) }
  let(:chat_client) { instance_double(Ai::Llm::Client) }
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:scope) { Knowledge::Page.all }

  def embedded_page(index, title:, body: "Contenuto", tech_spec: nil)
    create(:knowledge_page, organization: org, project: project, title: title, body: body, tech_spec: tech_spec).tap do |page|
      page.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  # generate_content(response_schema:) ritorna già l'Hash parsato (chiavi stringa).
  def chat_response(answer:, cited_ids:)
    { "answer" => answer, "cited_ids" => cited_ids }
  end

  def call_service(question: "che DB usiamo?")
    described_class.call(scope: scope, question: question, organization: org,
                         embed_client: embed_client, chat_client: chat_client)
  end

  it "risponde con citazioni verificate (solo id candidati reali)" do
    page = embedded_page(0, title: "Scelta database", body: "Usiamo PostgreSQL")
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])
    allow(chat_client).to receive(:generate_content)
      .and_return(chat_response(answer: "PostgreSQL [Scelta database]",
                                cited_ids: [ page.id, SecureRandom.uuid ]))

    result = call_service

    expect(result).to be_ok
    expect(result.value.answer).to include("PostgreSQL")
    expect(result.value.pages).to eq([ page ])
    expect(result.value.insufficient).to be(false)
  end

  it "passa al modello anche la sezione tecnica, non solo il corpo (CYRA-252)" do
    # La risposta vive SOLO nel tecnico: è ciò che rende la pagina il candidato migliore (entra
    # nell'embedding) ma finora non arrivava al prompt → il modello rispondeva «contesto insufficiente».
    page = embedded_page(0, title: "Rilascio app", body: "Come pubblicare una nuova versione.",
                         tech_spec: "Il comando esatto di rilascio è bin/deploy --tag stabile.")
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])
    captured_contents = nil
    allow(chat_client).to receive(:generate_content) do |contents:, **|
      captured_contents = contents
      chat_response(answer: "bin/deploy --tag stabile [Rilascio app]", cited_ids: [ page.id ])
    end

    call_service(question: "qual è il comando di rilascio?")

    user_content = captured_contents.last[:parts].first[:text]
    expect(user_content).to include("bin/deploy --tag stabile")
  end

  it "zero candidati sopra soglia → insufficient senza chiamare l'LLM" do
    embedded_page(1, title: "Palette colori")
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank)
    expect(chat_client).not_to receive(:generate_content)

    result = call_service
    expect(result).to be_ok
    expect(result.value.insufficient).to be(true)
    expect(result.value.pages).to eq([])
  end

  it "domanda vuota → err R422-KNOWLEDGE-003 senza toccare i servizi" do
    expect(chat_client).not_to receive(:generate_content)
    result = call_service(question: "   ")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-003")
  end

  it "servizio embedding giù → err (degrado del chiamante)" do
    allow(embed_client).to receive(:embed).and_raise(Ai::Embedding::Client::Error.new("giù", code: "R502-AI-001"))
    result = call_service
    expect(result).to be_err
  end

  it "LLM in errore → err col codice del provider" do
    embedded_page(0, title: "Scelta database")
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])
    allow(chat_client).to receive(:generate_content)
      .and_raise(Ai::Llm::Client::Error.new("busy", code: "R503-LLM-001", status: :service_unavailable))

    result = call_service
    expect(result).to be_err
    expect(result.error.code).to eq("R503-LLM-001")
  end

  # CYRA-765 — la risposta la dà il server AI del sistema: senza la sua configurazione si esce con
  # un errore leggibile, non con un 500.
  it "server AI non configurato → err R502-LLM-002, senza chiamare il modello" do
    embedded_page(0, title: "Scelta database")
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])
    allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

    result = described_class.call(scope: scope, question: "che DB usiamo?", organization: org,
                                  embed_client: embed_client)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-002")
  end
end
