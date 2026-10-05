# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Books::Save do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def call(book:, actor: owner, params:, page_ids: [])
    described_class.call(book: book, actor: actor, organization: org, params: params, page_ids: page_ids)
  end

  describe "creazione" do
    it "crea un book nel progetto visibile con autore e attributi" do
      result = call(book: Knowledge::Book.new, params: { project_id: project.id, title: "Manuale", description: "intro" })

      expect(result).to be_ok
      book = result.value
      expect(book).to be_persisted
      expect(book.title).to eq("Manuale")
      expect(book.description).to eq("intro")
      expect(book.project).to eq(project)
      expect(book.created_by).to eq(owner)
    end

    it "rifiuta un progetto non visibile all'autore (anti-BOLA) con R404-KNOWLEDGE-002" do
      # member senza project_membership non vede il progetto.
      result = call(book: Knowledge::Book.new, actor: member, params: { project_id: project.id, title: "X" })

      expect(result).to be_err
      expect(result.error.code).to eq("R404-KNOWLEDGE-002")
      expect(result.error.status).to eq(:not_found)
    end

    it "rifiuta il titolo vuoto con R422-KNOWLEDGE-004" do
      result = call(book: Knowledge::Book.new, params: { project_id: project.id, title: "" })

      expect(result).to be_err
      expect(result.error.code).to eq("R422-KNOWLEDGE-004")
      expect(result.error.details).to have_key(:title)
    end

    it "annulla anche le join quando il salvataggio fallisce" do
      other_project = create(:project, organization: org)
      book = create(:knowledge_book, organization: org, project: project, created_by: owner)

      result = call(book: book, params: { project_ids: [ other_project.id ], title: "" })

      expect(result).to be_err
      expect(book.reload.projects).to contain_exactly(project)
    end
  end

  describe "assegnazione pagine (ordine TOC)" do
    let!(:page_a) { create(:knowledge_page, organization: org, project: project, title: "A") }
    let!(:page_b) { create(:knowledge_page, organization: org, project: project, title: "B") }

    it "assegna book_id e position nell'ordine dei page_ids" do
      result = call(book: Knowledge::Book.new, params: { project_id: project.id, title: "Libro" },
                    page_ids: [ page_b.id, page_a.id ])

      expect(result).to be_ok
      book = result.value
      expect(page_b.reload.book_id).to eq(book.id)
      expect(page_b.position).to eq(0)
      expect(page_a.reload.book_id).to eq(book.id)
      expect(page_a.position).to eq(1)
    end

    it "scarta le pagine di un altro progetto (anti-BOLA), non le aggancia" do
      other_project = create(:project, organization: org)
      foreign = create(:knowledge_page, organization: org, project: other_project, title: "Estranea")

      result = call(book: Knowledge::Book.new, params: { project_id: project.id, title: "Libro" },
                    page_ids: [ page_a.id, foreign.id ])

      expect(result).to be_ok
      expect(page_a.reload.book_id).to eq(result.value.id)
      expect(foreign.reload.book_id).to be_nil
    end
  end

  describe "aggiornamento" do
    let!(:book) { create(:knowledge_book, organization: org, project: project, title: "Vecchio", created_by: owner) }
    let!(:page_a) { create(:knowledge_page, organization: org, project: project, book: book, position: 0, title: "A") }
    let!(:page_b) { create(:knowledge_page, organization: org, project: project, book: book, position: 1, title: "B") }

    it "aggiorna il titolo e sostituisce i progetti collegati" do
      other_project = create(:project, organization: org)
      result = call(book: book, params: { project_id: other_project.id, title: "Nuovo" }, page_ids: [ page_a.id, page_b.id ])

      expect(result).to be_ok
      expect(book.reload.title).to eq("Nuovo")
      expect(book.projects.reload).to contain_exactly(other_project)
    end


    it "collega progetti e gruppi e accetta pagine da tutti i progetti effettivi" do
      other_project = create(:project, organization: org)
      group = create(:group, organization: org)
      grouped_project = create(:project, organization: org, group: group)
      direct_page = create(:knowledge_page, organization: org, project: other_project)
      grouped_page = create(:knowledge_page, organization: org, project: grouped_project)

      result = call(book: book,
                    params: { project_ids: [ other_project.id ], group_ids: [ group.id ], title: "Condiviso" },
                    page_ids: [ grouped_page.id, direct_page.id ])

      expect(result).to be_ok
      expect(book.projects.reload).to contain_exactly(other_project)
      expect(book.groups.reload).to contain_exactly(group)
      expect(book.effective_projects).to contain_exactly(other_project, grouped_project)
      expect(grouped_page.reload.book_id).to eq(book.id)
      expect(direct_page.reload.book_id).to eq(book.id)
    end

    it "include una pagina collegata DIRETTAMENTE a un gruppo del book (non solo via progetto)" do
      group = create(:group, organization: org)
      create(:project, organization: org, group: group) # il gruppo ha ≥1 progetto → entra negli effective
      group_page = create(:knowledge_page, :org_wide, organization: org, title: "Pagina di gruppo")
      group_page.groups << group

      result = call(book: book, params: { group_ids: [ group.id ], title: "Book di gruppo" },
                    page_ids: [ group_page.id ])

      expect(result).to be_ok
      expect(group_page.reload.book_id).to eq(result.value.id)
    end

    it "rimuove dal book le pagine non più incluse (book_id → nil)" do
      result = call(book: book, params: { project_id: project.id, title: "Vecchio" }, page_ids: [ page_a.id ])

      expect(result).to be_ok
      expect(page_a.reload.book_id).to eq(book.id)
      expect(page_b.reload.book_id).to be_nil
    end

    it "stacca le pagine dei progetti rimossi dallo scope" do
      other_project = create(:project, organization: org)
      book.projects << other_project
      removed_page = create(:knowledge_page, organization: org, project: other_project, book: book)

      result = call(book: book, params: { project_ids: [ project.id ], title: book.title }, page_ids: [ page_a.id ])

      expect(result).to be_ok
      expect(removed_page.reload.book_id).to be_nil
    end

    it "sposta una pagina da un altro book dello stesso progetto" do
      other_book = create(:knowledge_book, organization: org, project: project, created_by: owner)
      moved = create(:knowledge_page, organization: org, project: project, book: other_book, title: "Spostata")

      result = call(book: book, params: { project_id: project.id, title: "Vecchio" },
                    page_ids: [ page_a.id, page_b.id, moved.id ])

      expect(result).to be_ok
      expect(moved.reload.book_id).to eq(book.id)
      expect(other_book.reload.pages).to be_empty
    end
  end
end
