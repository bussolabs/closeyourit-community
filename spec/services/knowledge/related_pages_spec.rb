# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::RelatedPages do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:scope) { Knowledge::Page.where(organization_id: organization.id) }

  # basis_vector(0) = argomento "deploy", basis_vector(1) = argomento scorrelato: la distanza
  # coseno tra i due è esattamente 1.0, ben oltre MAX_DISTANCE.
  def page(title:, vector: nil, in_project: project)
    create(:knowledge_page, organization: organization, project: in_project, title: title).tap do |record|
      if vector
        record.update_columns(embedding: vector, embedding_checksum: "x", embedded_at: Time.current,
                              embedding_version: Ai::Constants::EMBEDDING_VERSION)
      end
    end
  end

  def titles(rows) = rows.map { |row| row.page.title }

  describe "raccolta dei candidati" do
    it "unisce collegamenti espliciti e vicini semantici, marcando la provenienza" do
      source = page(title: "Rollback", vector: basis_vector(0))
      linked = page(title: "Deploy Kamal", vector: basis_vector(1))
      neighbour = page(title: "Runbook", vector: basis_vector(0))
      create(:page_link, page: source, related: linked)

      rows = described_class.call(pages: source, scope: scope)

      expect(rows.map { |row| [ row.page.title, row.via ] })
        .to contain_exactly([ "Deploy Kamal", :link ], [ neighbour.title, :semantic ])
    end

    it "il collegamento esplicito vince sulla semantica per la stessa pagina" do
      source = page(title: "Rollback", vector: basis_vector(0))
      both = page(title: "Deploy Kamal", vector: basis_vector(0))
      create(:page_link, page: source, related: both)

      rows = described_class.call(pages: source, scope: scope)

      expect(rows.map(&:via)).to eq([ :link ])
    end

    it "trova anche i collegamenti ENTRANTI (chi cita la pagina)" do
      source = page(title: "Rollback", vector: basis_vector(0))
      citing = page(title: "Guida operativa", vector: basis_vector(1))
      create(:page_link, page: citing, related: source)

      rows = described_class.call(pages: source, scope: scope)

      expect(titles(rows)).to eq([ "Guida operativa" ])
    end

    it "esclude le pagine sorgente da sé stesse" do
      source = page(title: "Rollback", vector: basis_vector(0))
      page(title: "Runbook", vector: basis_vector(0))

      rows = described_class.call(pages: source, scope: scope)

      expect(titles(rows)).not_to include("Rollback")
    end

    it "accetta più pagine sorgente insieme (citazioni di kb ask)" do
      first = page(title: "Rollback", vector: basis_vector(0))
      second = page(title: "Chiavi", vector: basis_vector(1))
      first_link = page(title: "Deploy Kamal", vector: basis_vector(1))
      second_link = page(title: "Rotazione", vector: basis_vector(1))
      create(:page_link, page: first, related: first_link)
      create(:page_link, page: second, related: second_link)

      rows = described_class.call(pages: [ first, second ], scope: scope, links_only: true)

      expect(titles(rows)).to contain_exactly("Deploy Kamal", "Rotazione")
    end

    it "non ripropone come correlata una pagina che è già una sorgente" do
      first = page(title: "Rollback", vector: basis_vector(0))
      second = page(title: "Deploy Kamal", vector: basis_vector(1))
      create(:page_link, page: first, related: second)

      rows = described_class.call(pages: [ first, second ], scope: scope, links_only: true)

      expect(rows).to be_empty
    end

    it "ritorna [] senza pagine sorgente" do
      expect(described_class.call(pages: [], scope: scope)).to eq([])
    end
  end

  describe "anti-leak" do
    it "esclude una pagina collegata che il chiamante NON può vedere" do
      source = page(title: "Rollback", vector: basis_vector(0))
      hidden_project = create(:project, organization: organization)
      hidden = page(title: "Segreto", vector: basis_vector(0), in_project: hidden_project)
      create(:page_link, page: source, related: hidden)

      visible_only = Knowledge::Page.where(id: project.knowledge_pages.select(:id))
      rows = described_class.call(pages: source, scope: visible_only)

      expect(titles(rows)).not_to include("Segreto")
    end
  end

  describe "pertinenza alla domanda" do
    let(:client) { instance_double(Ai::Embedding::Client) }

    it "ordina per pertinenza e scarta i collegamenti che non c'entrano con la domanda" do
      source = page(title: "Rollback", vector: basis_vector(2))
      pertinent = page(title: "Deploy Kamal", vector: basis_vector(0))
      off_topic = page(title: "Palette colori", vector: basis_vector(1))
      create(:page_link, page: source, related: pertinent)
      create(:page_link, page: source, related: off_topic)

      rows = described_class.call(pages: source, scope: scope, question_vector: basis_vector(0))

      expect(titles(rows)).to eq([ "Deploy Kamal" ])
      expect(rows.first.relevance).to be_within(0.001).of(1.0)
    end

    it "usa il vettore già calcolato senza richiamare il servizio embedding" do
      source = page(title: "Rollback", vector: basis_vector(2))
      create(:page_link, page: source, related: page(title: "Deploy Kamal", vector: basis_vector(0)))
      allow(Embeddings::QueryVector).to receive(:call)

      described_class.call(pages: source, scope: scope, question_vector: basis_vector(0))

      expect(Embeddings::QueryVector).not_to have_received(:call)
    end

    it "embedda la domanda quando riceve solo il testo" do
      source = page(title: "Rollback", vector: basis_vector(2))
      create(:page_link, page: source, related: page(title: "Deploy Kamal", vector: basis_vector(0)))
      allow(Embeddings::QueryVector).to receive(:call).and_return(Result.ok(basis_vector(0)))

      rows = described_class.call(pages: source, scope: scope, question: "come annullo un rilascio?", client: client)

      expect(Embeddings::QueryVector).to have_received(:call).with(query: "come annullo un rilascio?", client: client)
      expect(titles(rows)).to eq([ "Deploy Kamal" ])
    end

    it "tiene il collegamento non ancora indicizzato, in fondo e senza punteggio" do
      source = page(title: "Rollback", vector: basis_vector(2))
      scored = page(title: "Deploy Kamal", vector: basis_vector(0))
      unindexed = page(title: "Appena scritta")
      create(:page_link, page: source, related: scored)
      create(:page_link, page: source, related: unindexed)

      rows = described_class.call(pages: source, scope: scope, question_vector: basis_vector(0))

      expect(titles(rows)).to eq([ "Deploy Kamal", "Appena scritta" ])
      expect(rows.last.relevance).to be_nil
    end
  end

  describe "senza domanda" do
    it "mette prima i collegamenti espliciti, poi i vicini semantici" do
      source = page(title: "Rollback", vector: basis_vector(0))
      linked = page(title: "Deploy Kamal", vector: basis_vector(1))
      neighbour = page(title: "Runbook", vector: basis_vector(0))
      create(:page_link, page: source, related: linked)

      rows = described_class.call(pages: source, scope: scope)

      expect(titles(rows)).to eq([ linked.title, neighbour.title ])
      expect(rows.map(&:relevance)).to all(be_nil)
    end
  end

  describe "degrado" do
    it "con il servizio embedding giù risponde comunque, coi soli collegamenti e senza punteggio" do
      source = page(title: "Rollback", vector: basis_vector(2))
      create(:page_link, page: source, related: page(title: "Deploy Kamal", vector: basis_vector(0)))
      allow(Embeddings::QueryVector).to receive(:call)
        .and_return(Result.err(AppError.new("giù", code: "R502-AI-001")))

      rows = described_class.call(pages: source, scope: scope, question: "come annullo un rilascio?")

      expect(titles(rows)).to include("Deploy Kamal")
      expect(rows.first.relevance).to be_nil
    end

    it "sorgente senza embedding: niente vicini semantici, i collegamenti restano" do
      source = page(title: "Rollback")
      create(:page_link, page: source, related: page(title: "Deploy Kamal", vector: basis_vector(0)))
      page(title: "Runbook", vector: basis_vector(0))

      rows = described_class.call(pages: source, scope: scope)

      expect(titles(rows)).to eq([ "Deploy Kamal" ])
    end

    it "sorgente con embedding di versione superata: niente vicini semantici (CYRA-168)" do
      source = page(title: "Rollback", vector: basis_vector(0))
      source.update_columns(embedding_version: "qwen3-emb-0.6b-1024-v0")
      page(title: "Runbook", vector: basis_vector(0)) # sarebbe un vicino, ma la sorgente è stale

      rows = described_class.call(pages: source, scope: scope)

      expect(rows).to be_empty
    end
  end

  describe "modalità raggruppata (lista di risultati)" do
    it "ritorna i collegamenti di ciascuna sorgente, indicizzati per id" do
      first = page(title: "Rollback", vector: basis_vector(0))
      second = page(title: "Chiavi", vector: basis_vector(0))
      first_link = page(title: "Deploy Kamal", vector: basis_vector(1))
      second_link = page(title: "Rotazione", vector: basis_vector(1))
      create(:page_link, page: first, related: first_link)
      create(:page_link, page: second, related: second_link)

      grouped = described_class.call(pages: [ first, second ], scope: scope, grouped: true)

      expect(titles(grouped.fetch(first.id))).to eq([ "Deploy Kamal" ])
      expect(titles(grouped.fetch(second.id))).to eq([ "Rotazione" ])
    end

    it "omette le sorgenti senza collegamenti e non aggiunge vicini semantici" do
      lonely = page(title: "Rollback", vector: basis_vector(0))
      page(title: "Runbook", vector: basis_vector(0))

      expect(described_class.call(pages: lonely, scope: scope, grouped: true)).to eq({})
    end

    it "scarta i collegamenti non inerenti alla domanda anche raggruppati" do
      source = page(title: "Rollback", vector: basis_vector(2))
      create(:page_link, page: source, related: page(title: "Deploy Kamal", vector: basis_vector(0)))
      create(:page_link, page: source, related: page(title: "Palette colori", vector: basis_vector(1)))

      grouped = described_class.call(pages: source, scope: scope, grouped: true, question_vector: basis_vector(0))

      expect(titles(grouped.fetch(source.id))).to eq([ "Deploy Kamal" ])
    end

    it "mostra il collegamento anche fra due sorgenti, da entrambi i lati" do
      first = page(title: "Rollback", vector: basis_vector(0))
      second = page(title: "Deploy Kamal", vector: basis_vector(1))
      create(:page_link, page: first, related: second)

      grouped = described_class.call(pages: [ first, second ], scope: scope, grouped: true)

      expect(titles(grouped.fetch(first.id))).to eq([ "Deploy Kamal" ])
      expect(titles(grouped.fetch(second.id))).to eq([ "Rollback" ])
    end

    it "ritorna {} senza pagine sorgente" do
      expect(described_class.call(pages: [], scope: scope, grouped: true)).to eq({})
    end
  end

  describe "opzioni" do
    it "links_only esclude i vicini semantici" do
      source = page(title: "Rollback", vector: basis_vector(0))
      linked = page(title: "Deploy Kamal", vector: basis_vector(1))
      page(title: "Runbook", vector: basis_vector(0))
      create(:page_link, page: source, related: linked)

      rows = described_class.call(pages: source, scope: scope, links_only: true)

      expect(titles(rows)).to eq([ "Deploy Kamal" ])
    end

    it "rispetta il limite richiesto" do
      source = page(title: "Rollback", vector: basis_vector(0))
      3.times { |n| create(:page_link, page: source, related: page(title: "Collegata #{n}", vector: basis_vector(1))) }

      rows = described_class.call(pages: source, scope: scope, limit: 2)

      expect(rows.size).to eq(2)
    end
  end
end
