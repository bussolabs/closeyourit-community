# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Book, type: :model do
  describe "validazioni" do
    it "è valido con titolo, progetto e autore" do
      expect(build(:knowledge_book)).to be_valid
    end

    it "richiede il titolo (blank)" do
      book = build(:knowledge_book, title: "")
      expect(book).not_to be_valid
      expect(book.errors[:title]).to be_present
    end

    it "richiede il titolo (nil)" do
      expect(build(:knowledge_book, title: nil)).not_to be_valid
    end

    it "considera invalido un titolo di soli spazi (normalizzato a blank)" do
      book = build(:knowledge_book, title: "   ")
      expect(book).not_to be_valid
    end

    it "appartiene a un progetto" do
      expect(build(:knowledge_book, project: nil)).not_to be_valid
    end

    it "appartiene a un autore" do
      expect(build(:knowledge_book, created_by: nil)).not_to be_valid
    end
  end

  describe "normalizzazioni" do
    it "fa strip del titolo" do
      book = create(:knowledge_book, title: "  Manuale onboarding  ")
      expect(book.title).to eq("Manuale onboarding")
    end

    it "fa strip della descrizione, riduce i soli spazi a vuoto e lascia il nil (colonna nullable)" do
      expect(create(:knowledge_book, description: "  intro  ").description).to eq("intro")
      expect(create(:knowledge_book, description: "   ").description).to eq("")
      expect(create(:knowledge_book, description: nil).description).to be_nil
    end
  end

  describe "pagine (relazione + ordinamento)" do
    let(:org) { create(:organization) }
    let(:project) { create(:project, organization: org) }
    let(:book) { create(:knowledge_book, organization: org, project: project) }

    it "senza pagine ritorna una lista vuota (nessun crash)" do
      expect(book.pages).to be_empty
    end

    it "ordina le pagine per position, poi per titolo a parità" do
      second = create(:knowledge_page, organization: org, project: project, book: book, position: 1, title: "B")
      first  = create(:knowledge_page, organization: org, project: project, book: book, position: 0, title: "A")
      tie    = create(:knowledge_page, organization: org, project: project, book: book, position: 1, title: "A")

      expect(book.pages.to_a).to eq([ first, tie, second ])
    end

    it "elenca N pagine collegate" do
      create_list(:knowledge_page, 3, organization: org, project: project, book: book)
      expect(book.pages.count).to eq(3)
    end

    it "alla cancellazione del book le pagine sopravvivono orfane (book_id nil), non distrutte" do
      page = create(:knowledge_page, organization: org, project: project, book: book)

      expect { book.destroy }.to change(Knowledge::Page, :count).by(0)
      expect(page.reload.book_id).to be_nil
    end
  end

  describe "#authored_by?" do
    let(:book) { create(:knowledge_book) }

    it "è vero per l'autore" do
      expect(book.authored_by?(book.created_by)).to be(true)
    end

    it "è falso per un altro account" do
      expect(book.authored_by?(create(:account))).to be(false)
    end

    it "è falso per nil" do
      expect(book.authored_by?(nil)).to be(false)
    end
  end

  describe "progetti effettivi" do
    it "unisce progetti diretti e progetti dei gruppi senza duplicati" do
      org = create(:organization)
      group = create(:group, organization: org)
      grouped = create(:project, organization: org, group: group)
      direct = create(:project, organization: org)
      book = create(:knowledge_book, organization: org, project: grouped)
      book.projects << direct
      book.groups << group

      expect(book.effective_projects).to contain_exactly(grouped, direct)
    end

    it "richiede almeno un progetto o gruppo" do
      book = build(:knowledge_book)
      book.projects.clear

      expect(book).not_to be_valid
    end
  end

  describe ".ordered" do
    it "ordina per aggiornamento più recente" do
      old = create(:knowledge_book, updated_at: 2.days.ago)
      recent = create(:knowledge_book, updated_at: 1.hour.ago)
      expect(Knowledge::Book.ordered.to_a).to eq([ recent, old ])
    end
  end
end
