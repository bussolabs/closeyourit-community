# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Links::Suggest do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:scope) { Knowledge::Page.where(organization_id: org.id) }

  def suggest(query: nil, exclude_id: nil, from: scope)
    described_class.call(scope: from, organization: org, query: query, exclude_id: exclude_id)
  end

  it "senza query propone le pagine aggiornate più di recente" do
    create(:knowledge_page, organization: org, project: project, title: "Vecchia", updated_at: 3.days.ago)
    create(:knowledge_page, organization: org, project: project, title: "Recente", updated_at: 1.minute.ago)

    expect(suggest.map(&:title)).to eq([ "Recente", "Vecchia" ])
  end

  it "filtra per pezzo di titolo, senza distinguere maiuscole e minuscole" do
    create(:knowledge_page, organization: org, project: project, title: "Deploy Kamal")
    create(:knowledge_page, organization: org, project: project, title: "Rollback")

    expect(suggest(query: "kamal").map(&:title)).to eq([ "Deploy Kamal" ])
  end

  it "ordina alfabeticamente i titoli che corrispondono alla ricerca" do
    create(:knowledge_page, organization: org, project: project, title: "Deploy staging", updated_at: 1.minute.ago)
    create(:knowledge_page, organization: org, project: project, title: "Deploy Kamal", updated_at: 3.days.ago)

    expect(suggest(query: "deploy").map(&:title)).to eq([ "Deploy Kamal", "Deploy staging" ])
  end

  it "non propone la pagina che si sta scrivendo" do
    page = create(:knowledge_page, organization: org, project: project, title: "Deploy Kamal")

    expect(suggest(query: "deploy", exclude_id: page.id)).to be_empty
  end

  it "ignora un id di esclusione non valido invece di alzare un errore" do
    create(:knowledge_page, organization: org, project: project, title: "Deploy Kamal")

    expect(suggest(query: "deploy", exclude_id: "non-un-id").map(&:title)).to eq([ "Deploy Kamal" ])
  end

  it "non propone un titolo presente su più pagine dell'organizzazione: il collegamento non risolverebbe" do
    create(:knowledge_page, organization: org, project: project, title: "Deploy")
    create(:knowledge_page, organization: org, project: project, title: "Deploy")
    create(:knowledge_page, organization: org, project: project, title: "Deploy staging")

    expect(suggest(query: "deploy").map(&:title)).to eq([ "Deploy staging" ])
  end

  it "un titolo ambiguo SOLO per la pagina che lo scrive resta proponibile" do
    source = create(:knowledge_page, organization: org, project: project, title: "Deploy")
    create(:knowledge_page, organization: org, project: project, title: "Deploy")

    expect(suggest(query: "deploy", exclude_id: source.id).map(&:title)).to eq([ "Deploy" ])
  end

  it "ANTI-LEAK: propone solo le pagine dello scope ricevuto" do
    hidden_project = create(:project, organization: org)
    create(:knowledge_page, organization: org, project: hidden_project, title: "Riservata")
    visible = create(:knowledge_page, organization: org, project: project, title: "Pubblica")
    visible_scope = Knowledge::Page.where(id: visible.id)

    expect(suggest(from: visible_scope).map(&:title)).to eq([ "Pubblica" ])
  end

  it "non supera il tetto di suggerimenti" do
    (described_class::LIMIT + 3).times { |n| create(:knowledge_page, organization: org, project: project, title: "Pagina #{n}") }

    expect(suggest.size).to eq(described_class::LIMIT)
  end
end
