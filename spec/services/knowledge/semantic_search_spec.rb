# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::SemanticSearch do
  let(:client) { instance_double(Ai::Embedding::Client) }
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  def embedded_page(index, title:, version: Ai::Constants::EMBEDDING_VERSION)
    create(:knowledge_page, organization: org, project: project, title: title).tap do |page|
      page.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: version)
    end
  end

  it "ritorna gli id per pertinenza (rerank) filtrando per distanza" do
    near = embedded_page(0, title: "Backup del database")
    far = embedded_page(1, title: "Palette colori")
    _not_embedded = create(:knowledge_page, organization: org, project: project)

    allow(client).to receive(:embed).and_return([ blend_vector(0, 1, weight: 0.95) ])
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])

    result = described_class.call(scope: Knowledge::Page.all, query: "come backuppo il db", client: client)

    expect(result).to be_ok
    expect(result.value).to eq([ near.id ])
    expect(result.value).not_to include(far.id)
  end

  it "rerank fallito → degrada all'ordine coseno" do
    near = embedded_page(0, title: "Backup del database")
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(client).to receive(:rerank).and_raise(Ai::Embedding::Client::Error.new("giù", code: "R502-AI-001"))

    result = described_class.call(scope: Knowledge::Page.all, query: "backup", client: client)
    expect(result).to be_ok
    expect(result.value).to eq([ near.id ])
  end

  it "servizio embedding giù → err (il chiamante degrada a ILIKE)" do
    allow(client).to receive(:embed).and_raise(Ai::Embedding::Client::Error.new("giù", code: "R502-AI-001"))
    result = described_class.call(scope: Knowledge::Page.all, query: "backup", client: client)
    expect(result).to be_err
  end

  it "nessun candidato in soglia → lista vuota senza rerank" do
    embedded_page(1, title: "Palette colori")
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(client).to receive(:rerank)

    result = described_class.call(scope: Knowledge::Page.all, query: "backup", client: client)
    expect(result).to be_ok
    expect(result.value).to eq([])
    expect(client).not_to have_received(:rerank)
  end

  it "esclude le pagine embeddate con una versione del modello diversa dalla corrente (CYRA-168)" do
    current = embedded_page(0, title: "Versione corrente")
    embedded_page(0, title: "Versione vecchia", version: "qwen3-emb-0.6b-1024-v0") # stessa distanza, ma stale
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])

    result = described_class.call(scope: Knowledge::Page.all, query: "backup", client: client)

    expect(result).to be_ok
    expect(result.value).to eq([ current.id ]) # la pagina stale non entra mai fra i candidati
  end
end
