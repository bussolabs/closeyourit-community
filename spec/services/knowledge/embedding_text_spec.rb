# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::EmbeddingText do
  let(:page) { build(:knowledge_page, title: "Scelta database", body: "Usiamo PostgreSQL.", kind: :decision) }

  describe ".call" do
    it "compone titolo, tipo e contenuto con etichette fisse" do
      text = described_class.call(page: page)
      expect(text).to eq("Titolo: Scelta database\nTipo: decision\nContenuto: Usiamo PostgreSQL.")
    end

    it "aggiunge i dettagli tecnici quando tech_spec è presente" do
      page.tech_spec = "Indice HNSW su embedding vector(1024)."
      text = described_class.call(page: page)
      expect(text).to eq(
        "Titolo: Scelta database\nTipo: decision\nContenuto: Usiamo PostgreSQL." \
        "\nDettagli tecnici: Indice HNSW su embedding vector(1024)."
      )
    end

    it "lascia invariato il testo canonico quando tech_spec è assente (nessun re-embed del parco esistente)" do
      expect(described_class.call(page: page)).not_to include("Dettagli tecnici")
    end
  end

  describe ".checksum" do
    it "cambia al cambio di contenuto e incorpora la EMBEDDING_VERSION" do
      before = described_class.checksum(page: page)
      page.body = "Usiamo MySQL."
      expect(described_class.checksum(page: page)).not_to eq(before)

      page.body = "Usiamo PostgreSQL."
      stub_const("Ai::Constants::EMBEDDING_VERSION", "next-version")
      expect(described_class.checksum(page: page)).not_to eq(before)
    end

    it "cambia quando cambia tech_spec (il tecnico entra nel vettore)" do
      before = described_class.checksum(page: page)
      page.tech_spec = "Colonna vector(1024), opclass vector_cosine_ops."
      expect(described_class.checksum(page: page)).not_to eq(before)
    end
  end

  # Invariante di progetto, non dettaglio: Embeddings::EmbedText clampa a EMBED_MAX_CHARS prima di
  # calcolare il vettore. Finché una pagina al MASSIMO consentito ci sta sotto, nessun pezzo di
  # knowledge sparisce dall'indice in silenzio. Alzare un tetto senza alzare il budget rompe qui.
  it "sta nel budget dell'embedding anche con tutti i campi al massimo consentito" do
    page = build(:knowledge_page,
                 title: "t" * 255,
                 body: "b" * Knowledge::Constants::BODY_MAX_CHARS,
                 tech_spec: "s" * Knowledge::Constants::TECH_SPEC_MAX_CHARS,
                 kind: :decision)

    expect(page).to be_valid
    expect(described_class.call(page: page).length).to be <= Ai::Constants::EMBED_MAX_CHARS
  end

  it "espone le colonne watched del re-embed" do
    expect(described_class::WATCHED_COLUMNS).to contain_exactly("title", "kind", "body", "tech_spec")
  end
end
