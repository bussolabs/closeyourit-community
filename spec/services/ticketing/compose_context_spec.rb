# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::ComposeContext do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  def page(title)
    create(:knowledge_page, project: project, title: title, body: "corpo di #{title}")
  end

  def context(query: "il checkout va in timeout")
    described_class.call(project: project, query: query)
  end

  def semantic_search_returns(*ids)
    allow(Knowledge::SemanticSearch).to receive(:call).and_return(Result.ok(ids))
  end

  def snapshot_page(title, updated_at: Time.current)
    create(:knowledge_page, project: project, title: title, body: "corpo di #{title}",
                            tags: [ described_class::SNAPSHOT_TAG ]).tap do |snapshot|
      snapshot.update_column(:updated_at, updated_at)
    end
  end

  describe "quante pagine allega" do
    # Il numero è il punto della lavorazione: il modello va orientato, non sommerso.
    it "si ferma a due anche quando la ricerca ne trova cinque" do
      pages = Array.new(5) { |index| page("pagina #{index}") }
      semantic_search_returns(*pages.map(&:id))

      expect(context.size).to eq(described_class::MAX_PAGES)
    end

    # L'ordine è la pertinenza: tagliare in fondo vuol dire tenere le due migliori, non due a caso.
    it "tiene le prime due nell'ordine di pertinenza, non in quello di creazione" do
      first = page("timeout del gateway")
      second = page("politica di ripetizione")
      third = page("colori del bottone")
      semantic_search_returns(third.id, first.id, second.id)

      expect(context.map(&:title)).to eq([ "colori del bottone", "timeout del gateway" ])
    end
  end

  describe "quando non c'è niente da allegare" do
    # Knowledge::SemanticSearch taglia già il non pertinente (Embeddings::Rerank applica MIN_SCORE):
    # lista vuota vuol dire «nessuna pagina c'entra», e la risposta giusta è non allegare niente —
    # non ripiegare sulla pagina meno lontana, che è come inventare un contesto.
    it "torna vuoto quando la ricerca non trova nulla di pertinente" do
      page("una pagina che non c'entra")
      semantic_search_returns

      expect(context).to eq([])
    end

    # Il degrado del servizio di embedding è silenzioso per costruzione in tutta l'app: chi scrive un
    # ticket non deve accorgersi che Infinity è giù, e soprattutto non deve restare senza bozza.
    it "torna vuoto, senza sollevare, quando il servizio semantico è giù" do
      allow(Knowledge::SemanticSearch).to receive(:call)
        .and_return(Result.err(AppError.new("embedding giù", code: "R502-AI-002")))

      expect { context }.not_to raise_error
      expect(context).to eq([])
    end

    it "non interroga nemmeno la ricerca se non c'è testo" do
      allow(Knowledge::SemanticSearch).to receive(:call)

      expect(context(query: "   ")).to eq([])
      expect(Knowledge::SemanticSearch).not_to have_received(:call)
    end
  end

  describe "la fotografia del progetto (pagine taggate kb-init)" do
    # La fotografia è il contesto minimo garantito: viene dal DB, non dalla ricerca semantica,
    # quindi c'è anche quando la ricerca non trova nulla di pertinente.
    it "la allega anche quando la ricerca non trova nulla" do
      snapshot = snapshot_page("Fotografia — panoramica")
      semantic_search_returns

      expect(context).to eq([ snapshot ])
    end

    it "la allega anche quando il servizio semantico è giù" do
      snapshot = snapshot_page("Fotografia — panoramica")
      allow(Knowledge::SemanticSearch).to receive(:call)
        .and_return(Result.err(AppError.new("embedding giù", code: "R502-AI-002")))

      expect(context).to eq([ snapshot ])
    end

    it "si ferma a SNAPSHOT_MAX_PAGES tenendo le più aggiornate" do
      old = snapshot_page("vecchissima", updated_at: 4.days.ago)
      recent = Array.new(described_class::SNAPSHOT_MAX_PAGES) do |index|
        snapshot_page("recente #{index}", updated_at: index.hours.ago)
      end
      semantic_search_returns

      pages = context
      expect(pages.size).to eq(described_class::SNAPSHOT_MAX_PAGES)
      expect(pages).to match_array(recent)
      expect(pages).not_to include(old)
    end

    it "mette la fotografia in testa e le pagine pertinenti dopo, nell'ordine della ricerca" do
      relevant = page("timeout del gateway")
      snapshot = snapshot_page("Fotografia — panoramica")
      semantic_search_returns(relevant.id)

      expect(context).to eq([ snapshot, relevant ])
    end

    it "non duplica una pagina fotografia che esce anche dalla ricerca" do
      snapshot = snapshot_page("Fotografia — panoramica")
      relevant = page("timeout del gateway")
      semantic_search_returns(snapshot.id, relevant.id)

      expect(context).to eq([ snapshot, relevant ])
    end

    # La lista della ricerca è tutta sopra soglia: il posto liberato dal duplicato va alla pagina
    # pertinente successiva, non perso.
    it "un duplicato non consuma uno slot di pertinenza" do
      snapshot = snapshot_page("Fotografia — panoramica")
      first = page("timeout del gateway")
      second = page("politica di ripetizione")
      semantic_search_returns(snapshot.id, first.id, second.id)

      expect(context).to eq([ snapshot, first, second ])
    end

    # Stessa regola del pannello correlate (CYRA-298): una proposta non ancora accettata non deve
    # finire nel prompt, nemmeno se porta il tag della fotografia.
    it "esclude una pagina taggata ma ancora in revisione" do
      snapshot_page("Fotografia — panoramica").update!(status: :in_review)
      semantic_search_returns

      expect(context).to eq([])
    end

    it "resta fuori anche lei quando non c'è testo" do
      snapshot_page("Fotografia — panoramica")

      expect(context(query: "   ")).to eq([])
    end
  end

  describe "da dove pesca" do
    it "cerca nelle sole pagine agganciate al progetto o al suo gruppo" do
      scope = nil
      allow(Knowledge::SemanticSearch).to receive(:call) do |**kw|
        scope = kw[:scope]
        Result.ok([])
      end

      context
      expect(scope.to_sql).to eq(Knowledge::Page.related_to_project(project).to_sql)
    end
  end
end
