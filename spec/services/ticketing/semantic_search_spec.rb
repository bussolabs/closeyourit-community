# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::SemanticSearch do
  let(:client) { instance_double(Ai::Embedding::Client) }
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  def seeded_ticket(index, title: "Ticket #{index}", version: Ai::Constants::EMBEDDING_VERSION)
    create(:ticket, organization: org, project: project, title: title).tap do |t|
      t.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                       embedded_at: Time.current, embedding_version: version)
    end
  end

  it "ritorna gli id ordinati per pertinenza (rerank sopra il retrieval coseno)" do
    near = seeded_ticket(0)
    other = seeded_ticket(1)
    allow(client).to receive(:embed).and_return([ blend_vector(0, 1, weight: 0.9) ])
    # Il cross-encoder ribalta l'ordine del coseno: vince `other`.
    allow(client).to receive(:rerank).and_return([ { index: 1, score: 0.9 }, { index: 0, score: 0.2 } ])

    # Query di due parole: qui si guarda l'ordinamento, non il taglio delle query cortissime.
    result = described_class.call(scope: Ticketing::Ticket.all, query: "due parole", client: client)

    expect(result).to be_ok
    expect(result.value).to eq([ other.id, near.id ])
  end

  it "esclude i candidati oltre la soglia di distanza" do
    near = seeded_ticket(0)
    seeded_ticket(7) # ortogonale alla query → distanza 1.0 > 0.6
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])

    expect(described_class.call(scope: Ticketing::Ticket.all, query: "q", client: client).value)
      .to eq([ near.id ])
  end

  it "una query di UNA parola stringe la soglia: a 0.6 passava anche ciò che non c'entra (CYRA-553)" do
    seeded_ticket(0, title: "Vicino a metà strada")
    # distanza 0.5: dentro la soglia larga (0.6), fuori da quella delle query di una parola (0.45).
    allow(client).to receive(:embed).and_return([ blend_vector(0, 1, weight: 0.5) ])
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])

    expect(described_class.call(scope: Ticketing::Ticket.all, query: "inventata", client: client).value).to eq([])
  end

  it "con due parole la soglia larga resta: la query porta già contesto suo" do
    ticket = seeded_ticket(0, title: "Vicino a metà strada")
    allow(client).to receive(:embed).and_return([ blend_vector(0, 1, weight: 0.5) ])
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])

    expect(described_class.call(scope: Ticketing::Ticket.all, query: "due parole", client: client).value)
      .to eq([ ticket.id ])
  end

  it "candidati giudicati non pertinenti dal rerank → nessun risultato (CYRA-553)" do
    seeded_ticket(0, title: "Crash al login")
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    # Il cross-encoder risponde sempre, anche a una parola inventata: i punteggi bassi sono il
    # segnale che non c'entra nulla, e vanno tagliati invece di essere presentati come risultati.
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.001 } ])

    expect(described_class.call(scope: Ticketing::Ticket.all, query: "qwertyuiop asdf", client: client).value)
      .to eq([])
  end

  it "manda al cross-encoder pochi documenti corti: è quello a costare i mezzi minuti (CYRA-553)" do
    25.times { |i| seeded_ticket(0, title: "Ticket #{i}").update_columns(description: "x" * 2_000) }
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(client).to receive(:rerank) do |query:, documents:, **|
      expect(query).to eq("crash al login")
      expect(documents.size).to eq(Embeddings::Relevance::RERANK_TOP_N)
      expect(documents.map(&:length).max).to eq(Embeddings::Relevance::RERANK_TEXT_CHARS)
      [ { index: 0, score: 0.9 } ]
    end

    result = described_class.call(scope: Ticketing::Ticket.all, query: "crash al login", client: client)

    expect(result).to be_ok
    expect(client).to have_received(:rerank)
  end

  it "rispetta la scope passata (un ticket fuori scope non entra mai nei candidati)" do
    mine = seeded_ticket(0)
    other_org = create(:organization)
    foreign = create(:ticket, organization: other_org, project: create(:project, organization: other_org))
    foreign.update_columns(embedding: basis_vector(0), embedding_checksum: "x", embedded_at: Time.current)
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])

    result = described_class.call(scope: Ticketing::Ticket.where(project_id: project.id),
                                  query: "q", client: client)

    expect(result.value).to eq([ mine.id ])
  end

  it "nessun candidato (ticket senza embedding) → Result.ok([]) senza rerank" do
    create(:ticket, organization: org, project: project)
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    expect(client).not_to receive(:rerank)

    expect(described_class.call(scope: Ticketing::Ticket.all, query: "q", client: client).value).to eq([])
  end

  it "rerank fallito → degrado interno all'ordine coseno (mai errore)" do
    near = seeded_ticket(0)
    far = seeded_ticket(1)
    allow(client).to receive(:embed).and_return([ blend_vector(0, 1, weight: 0.9) ])
    allow(client).to receive(:rerank)
      .and_raise(Ai::Embedding::Client::Error.new("giù", code: "R502-AI-001"))

    expect(described_class.call(scope: Ticketing::Ticket.all, query: "due parole", client: client).value)
      .to eq([ near.id, far.id ])
  end

  it "servizio embedding giù sull'embed della query → Result.err (il chiamante degrada)" do
    allow(client).to receive(:embed)
      .and_raise(Ai::Embedding::Client::Error.new("timeout", code: "R504-AI-001", status: :gateway_timeout))

    result = described_class.call(scope: Ticketing::Ticket.all, query: "q", client: client)

    expect(result).to be_err
    expect(result.error.code).to eq("R504-AI-001")
  end

  it "esclude i ticket embeddati con una versione del modello diversa dalla corrente (CYRA-168)" do
    current = seeded_ticket(0, title: "Versione corrente")
    seeded_ticket(0, title: "Versione vecchia", version: "qwen3-emb-0.6b-1024-v0") # stessa distanza, ma stale
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])

    result = described_class.call(scope: Ticketing::Ticket.all, query: "q", client: client)

    expect(result).to be_ok
    expect(result.value).to eq([ current.id ]) # la riga stale non entra mai fra i candidati
  end
end
