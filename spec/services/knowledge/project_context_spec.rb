# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ProjectContext do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:scope) { Knowledge::Page.where(organization_id: organization.id) }

  def context_for(project_record = project, **options)
    described_class.call(project: project_record, scope: scope, **options)
  end

  it "elenca le pagine del progetto dalla più recente alla più vecchia" do
    old = create(:knowledge_page, organization:, project:, title: "Vecchia")
    recent = create(:knowledge_page, organization:, project:, title: "Recente")
    old.update_column(:updated_at, 3.days.ago)
    recent.update_column(:updated_at, 1.hour.ago)

    expect(context_for.map { |row| row.page.id }).to eq([ recent.id, old.id ])
  end

  it "taglia l'elenco al tetto anche quando le pagine sono molte" do
    create_list(:knowledge_page, described_class::DEFAULT_LIMIT + 3, organization:, project:)

    expect(context_for.size).to eq(described_class::DEFAULT_LIMIT)
  end

  it "accetta un tetto più basso e non supera mai quello massimo" do
    create_list(:knowledge_page, 3, organization:, project:)

    expect(context_for(limit: 2).size).to eq(2)
    expect(described_class.new(project:, scope:, limit: 10_000).limit).to eq(described_class::MAX_LIMIT)
    expect(described_class.new(project:, scope:, limit: 0).limit).to eq(described_class::DEFAULT_LIMIT)
    expect(described_class.new(project:, scope:, limit: "sette").limit).to eq(described_class::DEFAULT_LIMIT)
  end

  it "lascia fuori le proposte in attesa e quelle scartate" do
    published = create(:knowledge_page, organization:, project:, title: "Accettata")
    create(:knowledge_page, :in_review, organization:, project:, title: "In attesa")
    create(:knowledge_page, :rejected, organization:, project:, title: "Scartata")

    expect(context_for.map { |row| row.page.id }).to eq([ published.id ])
  end

  it "lascia fuori le pagine di altri progetti e quelle generali dell'organizzazione" do
    mine = create(:knowledge_page, organization:, project:)
    create(:knowledge_page, organization:, project: create(:project, organization:))
    create(:knowledge_page, :org_wide, organization:)

    expect(context_for.map { |row| row.page.id }).to eq([ mine.id ])
  end

  it "include le pagine collegate al gruppo del progetto" do
    group = create(:group, organization:)
    project.update!(group: group)
    page = create(:knowledge_page, organization:, scoped: false)
    page.groups << group

    expect(context_for.map { |row| row.page.id }).to eq([ page.id ])
  end

  it "resta dentro lo scope ricevuto: quello che il chiamante non vede non compare" do
    create(:knowledge_page, organization:, project:, title: "Fuori scope")

    rows = described_class.call(project: project, scope: Knowledge::Page.none)
    expect(rows).to be_empty
  end

  it "torna un elenco vuoto quando il progetto non ha ancora pagine" do
    expect(context_for).to eq([])
  end

  describe "la riga di riassunto" do
    it "salta i titoli markdown e riporta le prime righe di testo su una riga sola" do
      page = create(:knowledge_page, organization:, project:,
                                     body: "# Titolo\n\nPrima riga del corpo.\nSeconda riga del corpo.")

      expect(context_for.first.summary).to eq("Prima riga del corpo. Seconda riga del corpo.")
    end

    it "tronca a SUMMARY_CHARS caratteri" do
      page = create(:knowledge_page, organization:, project:, body: "a" * 400)

      summary = context_for.first.summary
      expect(summary.length).to eq(described_class::SUMMARY_CHARS)
      expect(summary).to end_with("...")
    end

    it "è nulla quando il corpo è fatto di soli titoli" do
      create(:knowledge_page, organization:, project:, body: "# Solo titolo")

      expect(context_for.first.summary).to be_nil
    end
  end
end
