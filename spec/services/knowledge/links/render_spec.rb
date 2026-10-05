# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Links::Render do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }

  def page(title:, body: "Contenuto senza riferimenti.")
    create(:knowledge_page, organization: organization, project: project, title: title, body: body)
  end

  def render(source) = described_class.call(text: source.body, page: source)

  it "trasforma il wikilink risolto in un link markdown alla pagina" do
    target = page(title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")
    Knowledge::Links::Sync.call(page: source)

    expect(render(source)).to eq("Segue [Deploy Kamal](/member/knowledge/pages/#{target.id}).")
  end

  it "usa la label dopo la pipe come testo del link" do
    target = page(title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Vedi [[Deploy Kamal|la guida al deploy]].")
    Knowledge::Links::Sync.call(page: source)

    expect(render(source)).to eq("Vedi [la guida al deploy](/member/knowledge/pages/#{target.id}).")
  end

  it "lascia intatto un wikilink non risolto" do
    source = page(title: "Rollback", body: "Segue [[Pagina mai scritta]].")

    expect(render(source)).to eq("Segue [[Pagina mai scritta]].")
  end

  it "continua a funzionare dopo la rinomina della destinazione" do
    target = page(title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")
    Knowledge::Links::Sync.call(page: source)
    target.update!(title: "Rilascio con Kamal")

    expect(render(source)).to eq("Segue [Deploy Kamal](/member/knowledge/pages/#{target.id}).")
  end

  it "non tocca i wikilink dentro un blocco di codice" do
    page(title: "Deploy Kamal")
    body = "Vedi [[Deploy Kamal]]\n```\nscrivi [[Deploy Kamal]]\n```\n"
    source = page(title: "Guida", body: body)
    Knowledge::Links::Sync.call(page: source)

    expect(render(source)).to include("scrivi [[Deploy Kamal]]")
    expect(render(source)).to include("[Deploy Kamal](/member/knowledge/pages/")
  end

  it "non tocca i wikilink dentro un code span inline" do
    page(title: "Deploy Kamal")
    source = page(title: "Guida", body: "per collegare scrivi `[[Deploy Kamal]]` nel testo")
    Knowledge::Links::Sync.call(page: source)

    expect(render(source)).to eq("per collegare scrivi `[[Deploy Kamal]]` nel testo")
  end

  it "neutralizza le parentesi tonde nella label (non spezza il link)" do
    target = page(title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Vedi [[Deploy Kamal|guida (2026)]].")
    Knowledge::Links::Sync.call(page: source)

    expect(render(source)).to eq("Vedi [guida \\(2026\\)](/member/knowledge/pages/#{target.id}).")
  end

  it "restituisce il testo invariato quando la pagina non ha collegamenti" do
    source = page(title: "Rollback", body: "Nessun riferimento.")

    expect(render(source)).to eq("Nessun riferimento.")
  end
end
