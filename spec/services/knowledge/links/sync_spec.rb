# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Links::Sync do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:other_project) { create(:project, organization: organization) }

  def page(title:, body: "Contenuto senza riferimenti.", in_project: project)
    create(:knowledge_page, organization: organization, project: in_project, title: title, body: body)
  end

  def linked_pages(source)
    source.links.reload.map(&:related)
  end

  it "collega la pagina citata nello stesso progetto" do
    target = page(title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")

    described_class.call(page: source)

    expect(linked_pages(source)).to eq([ target ])
  end

  it "salva il titolo così com'è scritto nel wikilink (chiave per la resa)" do
    page(title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Vedi [[Deploy Kamal|la guida]].")

    described_class.call(page: source)

    expect(source.links.reload.first.target_title).to eq("Deploy Kamal")
  end

  it "conserva il titolo scritto anche dopo la rinomina della destinazione" do
    target = page(title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")
    described_class.call(page: source)

    target.update!(title: "Rilascio con Kamal")

    expect(source.links.reload.first).to have_attributes(target_title: "Deploy Kamal", related: target)
  end

  it "risolve un titolo di un ALTRO progetto della stessa organizzazione" do
    target = page(title: "Deploy Kamal", in_project: other_project)
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")

    described_class.call(page: source)

    expect(linked_pages(source)).to eq([ target ])
  end

  it "non disambigua più per progetto: un titolo in due progetti della stessa org è ambiguo" do
    page(title: "Deploy Kamal", in_project: other_project)
    page(title: "Deploy Kamal") # stesso progetto della source
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")

    described_class.call(page: source)

    expect(source.links.reload).to be_empty
  end

  it "non collega nulla se il titolo è ambiguo nell'organizzazione" do
    third_project = create(:project, organization: organization)
    page(title: "Deploy Kamal", in_project: other_project)
    page(title: "Deploy Kamal", in_project: third_project)
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")

    described_class.call(page: source)

    expect(source.links.reload).to be_empty
  end

  it "ignora un titolo che non esiste" do
    source = page(title: "Rollback", body: "Segue [[Pagina mai scritta]].")

    described_class.call(page: source)

    expect(source.links.reload).to be_empty
  end

  it "ignora l'auto-riferimento" do
    source = page(title: "Rollback", body: "Vedi [[Rollback]] cioè me stessa.")

    described_class.call(page: source)

    expect(source.links.reload).to be_empty
  end

  it "non collega una pagina di un'ALTRA organizzazione" do
    create(:knowledge_page, title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")

    described_class.call(page: source)

    expect(source.links.reload).to be_empty
  end

  it "risolve il titolo ignorando maiuscole e spazi ai bordi" do
    target = page(title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Segue [[  deploy KAMAL  ]].")

    described_class.call(page: source)

    expect(linked_pages(source)).to eq([ target ])
  end

  it "ignora i wikilink dentro il codice" do
    page(title: "Deploy Kamal")
    source = page(title: "Guida", body: "per collegare scrivi `[[Deploy Kamal]]` nel testo")

    described_class.call(page: source)

    expect(source.links.reload).to be_empty
  end

  it "riscrive i collegamenti ad ogni sync: aggiunge i nuovi e toglie quelli spariti" do
    first = page(title: "Deploy Kamal")
    second = page(title: "Rotazione chiavi")
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")
    described_class.call(page: source)
    expect(linked_pages(source)).to eq([ first ])

    source.update!(body: "Ora presuppone [[Rotazione chiavi]].")
    described_class.call(page: source)

    expect(linked_pages(source)).to eq([ second ])
  end

  it "svuota i collegamenti quando il corpo non cita più nessuno" do
    page(title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")
    described_class.call(page: source)

    source.update!(body: "Nessun riferimento.")
    described_class.call(page: source)

    expect(source.links.reload).to be_empty
  end

  it "collega più pagine e ritorna gli id nell'ordine di apparizione" do
    first = page(title: "Deploy Kamal")
    second = page(title: "Rotazione chiavi")
    source = page(title: "Rollback", body: "Prima [[Deploy Kamal]], poi [[Rotazione chiavi]].")

    expect(described_class.call(page: source)).to eq([ first.id, second.id ])
    expect(linked_pages(source)).to contain_exactly(first, second)
  end

  it "non tocca il database quando non c'è nulla da collegare né da rimuovere" do
    source = page(title: "Rollback", body: "Nessun riferimento.")

    expect { described_class.call(page: source) }.not_to change(Connections::PageLink, :count)
  end
end
