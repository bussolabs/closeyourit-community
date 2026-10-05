# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::AskTickets do
  let(:embed_client) { instance_double(Ai::Embedding::Client) }
  let(:chat_client) { instance_double(Ai::Llm::Client) }
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  def seeded_ticket(index, title: "Ticket #{index}")
    create(:ticket, organization: org, project: project, title: title).tap do |t|
      t.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                       embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  # generate_content(response_schema:) ritorna già l'Hash parsato (chiavi stringa).
  def chat_response(answer:, cited_ids: [])
    { "answer" => answer, "cited_ids" => cited_ids }
  end

  def call(scope: Ticketing::Ticket.all, question: "che problemi abbiamo col login?", organization: org)
    described_class.call(scope:, question:, organization:, embed_client:, chat_client:)
  end

  it "risponde con citazioni verificate (solo candidati reali)" do
    ticket = seeded_ticket(0, title: "Crash al login")
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])
    allow(chat_client).to receive(:generate_content)
      .and_return(chat_response(answer: "Sì, vedi [#{ticket.code}]",
                                cited_ids: [ ticket.id, SecureRandom.uuid ])) # il secondo è allucinato

    result = call

    expect(result).to be_ok
    expect(result.value.insufficient).to be(false)
    expect(result.value.answer).to include(ticket.code)
    expect(result.value.tickets.map(&:id)).to eq([ ticket.id ]) # l'allucinato è scartato
  end

  it "il contesto passa dal prompt: id, codice e commenti recenti dei candidati" do
    ticket = seeded_ticket(0, title: "Crash al login")
    create(:ticket_comment, organization: org, ticket: ticket, body: "Riprodotto su Safari 17")
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])
    allow(chat_client).to receive(:generate_content) do |system:, contents:, **|
      expect(system).to include("cited_ids")
      text = contents.last[:parts].first[:text]
      expect(text).to include(ticket.id)
      expect(text).to include(ticket.code)
      expect(text).to include("Riprodotto su Safari 17")
      chat_response(answer: "ok", cited_ids: [ ticket.id ])
    end

    expect(call).to be_ok
  end

  it "guardrail: nessun candidato sopra soglia → insufficient SENZA chiamare l'LLM" do
    seeded_ticket(7, title: "Lontanissimo")
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank).and_return([]) # non deve nemmeno arrivarci
    expect(chat_client).not_to receive(:generate_content)

    result = call

    expect(result).to be_ok
    expect(result.value.insufficient).to be(true)
    expect(result.value.tickets).to eq([])
  end

  it "domanda blank → R422-TICKET-005 senza chiamare nulla" do
    expect(embed_client).not_to receive(:embed)
    expect(chat_client).not_to receive(:generate_content)

    result = call(question: "   ")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-005")
  end

  it "rerank giù → si prosegue con l'ordine coseno (la feature non si spegne)" do
    ticket = seeded_ticket(0)
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank)
      .and_raise(Ai::Embedding::Client::Error.new("giù", code: "R502-AI-001"))
    allow(chat_client).to receive(:generate_content).and_return(chat_response(answer: "ok", cited_ids: [ ticket.id ]))

    expect(call).to be_ok
  end

  it "servizio embedding giù → Result.err propagato" do
    allow(embed_client).to receive(:embed)
      .and_raise(Ai::Embedding::Client::Error.new("timeout", code: "R504-AI-001", status: :gateway_timeout))

    result = call

    expect(result).to be_err
    expect(result.error.code).to eq("R504-AI-001")
  end

  it "provider chat giù → Result.err con codice e status del client" do
    seeded_ticket(0)
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])
    allow(chat_client).to receive(:generate_content)
      .and_raise(Ai::Llm::Client::Error.new("timeout", code: "R504-LLM-001", status: :gateway_timeout))

    result = call

    expect(result).to be_err
    expect(result.error.code).to eq("R504-LLM-001")
    expect(result.error.status).to eq(:gateway_timeout)
  end

  it "output AI illeggibile (JSON non valido dal modello) → errore del client, mai un'eccezione" do
    seeded_ticket(0)
    allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(embed_client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])
    allow(chat_client).to receive(:generate_content)
      .and_raise(Ai::Llm::Client::Error.new("JSON non valido", code: "R502-LLM-005"))

    result = call

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-005")
  end

  # CYRA-765 — la risposta la dà il server AI del sistema. Quel che può mancare è la sua
  # configurazione: la domanda torna indietro dicendo cosa manca, non un errore del fornitore.
  describe "il server AI non configurato" do
    it "non chiama il modello e torna R502-LLM-002" do
      seeded_ticket(0)
      allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
      allow(embed_client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])
      allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

      result = described_class.call(scope: Ticketing::Ticket.all, question: "che problemi abbiamo?",
                                    organization: org, embed_client: embed_client)

      expect(result).to be_err
      expect(result.error.code).to eq("R502-LLM-002")
      expect(result.error.status).to eq(:bad_gateway)
    end

    it "senza client iniettato se lo costruisce da sé, senza chiedere niente all'organizzazione" do
      seeded_ticket(0)
      allow(embed_client).to receive(:embed).and_return([ basis_vector(0) ])
      allow(embed_client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])
      allow(Ai::Llm::Client).to receive(:new).and_return(chat_client)
      allow(chat_client).to receive(:generate_content).and_return(chat_response(answer: "Sì"))

      described_class.call(scope: Ticketing::Ticket.all, question: "che problemi abbiamo?",
                           organization: org, embed_client: embed_client)

      expect(Ai::Llm::Client).to have_received(:new).with(no_args)
    end
  end
end
