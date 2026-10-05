# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Books::AddPage do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:book) { create(:knowledge_book, organization:, project:) }

  def page(title, book: nil, position: 0)
    create(:knowledge_page, organization:, project:, book:, position:, title:)
  end

  it "aggiunge la pagina in fondo quando la posizione non è indicata" do
    a = page("A", book:, position: 0)
    b = page("B", book:, position: 1)
    free = page("C")

    result = described_class.call(book:, page: free)

    expect(result).to be_ok
    expect(book.pages.reload.map(&:id)).to eq([ a.id, b.id, free.id ])
    expect(book.pages.map(&:position)).to eq([ 0, 1, 2 ])
  end

  it "inserisce la pagina alla posizione richiesta e ricompatta le posizioni" do
    a = page("A", book:, position: 0)
    b = page("B", book:, position: 1)
    free = page("C")

    described_class.call(book:, page: free, position: 1)

    expect(book.pages.reload.map(&:id)).to eq([ a.id, free.id, b.id ])
    expect(book.pages.map(&:position)).to eq([ 0, 1, 2 ])
  end

  it "clampa una posizione oltre i limiti in coda" do
    a = page("A", book:, position: 0)
    free = page("C")

    described_class.call(book:, page: free, position: 99)

    expect(book.pages.reload.map(&:id)).to eq([ a.id, free.id ])
  end

  it "è idempotente: ripetere la stessa aggiunta non duplica né cambia l'ordine" do
    a = page("A", book:, position: 0)
    free = page("C")

    2.times { described_class.call(book:, page: free, position: 1) }

    expect(book.pages.reload.map(&:id)).to eq([ a.id, free.id ])
    expect(book.pages.map(&:position)).to eq([ 0, 1 ])
  end

  it "rifiuta una pagina che non appartiene ai progetti del book (R422-KNOWLEDGE-006)" do
    outsider = create(:knowledge_page, organization:, project: create(:project, organization:))

    result = described_class.call(book:, page: outsider)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-006")
    expect(result.error.status).to eq(:unprocessable_content)
    expect(outsider.reload.book_id).to be_nil
  end

  # I due casi che il controllo pre-CYRA-174 sbagliava: usava @page.project_id, cioe' lo shim che
  # restituisce il PRIMO progetto della pagina (o nil), invece dell'intersezione fra i progetti
  # effettivi di pagina e book. Con project_id la prima passava solo per caso e la seconda passava
  # quando non doveva (nil confrontato con una lista).
  it "accetta una pagina multi-progetto se ALMENO UNO dei suoi progetti e' nel book" do
    altro = create(:project, organization:)
    multi = create(:knowledge_page, organization:, project: altro)
    multi.projects << project # secondo progetto: e' quello del book

    result = described_class.call(book:, page: multi)

    expect(result).to be_ok
    expect(multi.reload.book_id).to eq(book.id)
  end

  it "rifiuta una pagina org-wide, che non ha alcun progetto in comune col book" do
    org_wide = create(:knowledge_page, :org_wide, organization:)

    result = described_class.call(book:, page: org_wide)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-006")
    expect(org_wide.reload.book_id).to be_nil
  end

  it "accetta una pagina di un progetto raggiunto tramite gruppo del book" do
    group = create(:group, organization:)
    grouped_project = create(:project, organization:, group:)
    grouped_book = create(:knowledge_book, organization:, created_by: create(:account))
    grouped_book.groups << group
    grouped_book.save!
    grouped_page = create(:knowledge_page, organization:, project: grouped_project)

    result = described_class.call(book: grouped_book, page: grouped_page)

    expect(result).to be_ok
    expect(grouped_page.reload.book_id).to eq(grouped_book.id)
  end

  it "rifiuta una pagina già associata a un altro book, lasciandola dov'è (R422-KNOWLEDGE-007)" do
    other_book = create(:knowledge_book, organization:, project:)
    occupied = page("Occupata", book: other_book, position: 0)

    result = described_class.call(book:, page: occupied)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-007")
    expect(occupied.reload.book_id).to eq(other_book.id)
  end

  it "l'aggiunta tocca updated_at del book (risale per ultima modifica)" do
    free = page("C")
    before = book.updated_at

    travel_to(1.minute.from_now) { described_class.call(book:, page: free) }

    expect(book.reload.updated_at).to be > before
  end
end
