# frozen_string_literal: true

require "rails_helper"

# Vista Books stile Outline (rack_test: navigazione server-side dell'indice/contenuto; il riordino
# fine drag-drop è fuori scope v1). Scenario 1 del ticket: indice a sinistra, contenuto a destra,
# pagina attiva evidenziata, contenuto markdown reso.
RSpec.describe "Member knowledge — books", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "Scenario 1: apre la show del book e naviga le pagine dall'indice (TOC a sinistra, markdown a destra)" do
    book = create(:knowledge_book, organization: org, project: project, title: "Guida prodotto")
    first = create(:knowledge_page, organization: org, project: project, book: book, position: 0,
                                    title: "Introduzione", body: "## Benvenuto\n\nPrologo.")
    second = create(:knowledge_page, organization: org, project: project, book: book, position: 1,
                                     title: "Installazione", body: "## Setup\n\nPassi di installazione.")
    sign_in_as(owner)

    visit member_knowledge_book_path(book)

    # Indice a sinistra: entrambe le pagine come voci.
    within_test("knowledge-book-toc") do
      expect(page).to have_text("Introduzione")
      expect(page).to have_text("Installazione")
    end
    # Contenuto a destra: la prima pagina resa in markdown, voce attiva evidenziata.
    within_test("knowledge-book-content") { expect(page).to have_css("h2", text: "Benvenuto") }
    expect(page).to have_css("[data-test='knowledge-book-toc-link-#{first.id}'][aria-current='page']")

    # Navigo alla seconda pagina dall'indice: il contenuto cambia e l'evidenziazione si sposta.
    find("[data-test='knowledge-book-toc-link-#{second.id}']").click
    within_test("knowledge-book-content") { expect(page).to have_css("h2", text: "Setup") }
    expect(page).to have_css("[data-test='knowledge-book-toc-link-#{second.id}'][aria-current='page']")
    expect(page).to have_no_css("[data-test='knowledge-book-toc-link-#{first.id}'][aria-current='page']")
  end

  it "crea un book dal form e lo apre (vuoto) mostrando lo stato vuoto" do
    sign_in_as(owner)
    visit new_member_knowledge_book_path

    fill_test "knowledge-book-form-title", with: "Runbook operativo"
    find("[data-test='knowledge-book-form-projects']", visible: :all)
      .find("option[value='#{project.id}']").select_option
    click_on_test "knowledge-book-form-submit"

    book = Knowledge::Book.find_by(title: "Runbook operativo")
    expect(book).to be_present
    expect_test "knowledge-book"
    expect_test "knowledge-book-empty"
  end

  it "assegna pagine a un book dall'edit e le mostra nell'indice" do
    book = create(:knowledge_book, organization: org, project: project, title: "Manuale", created_by: owner)
    create(:knowledge_page, organization: org, project: project, title: "Capitolo uno")
    create(:knowledge_page, organization: org, project: project, title: "Capitolo due")
    sign_in_as(owner)

    visit edit_member_knowledge_book_path(book)
    select_el = find("[data-test='knowledge-book-form-pages']", visible: :all)
    select_el.find("option", text: "#{project.name} · Capitolo uno").select_option
    select_el.find("option", text: "#{project.name} · Capitolo due").select_option
    click_on_test "knowledge-book-form-submit"

    expect_test "knowledge-book"
    within_test("knowledge-book-toc") do
      expect(page).to have_text("Capitolo uno")
      expect(page).to have_text("Capitolo due")
    end
  end

  it "dall'indice delle pagine si raggiunge la vista Books" do
    sign_in_as(owner)
    visit member_knowledge_pages_path
    click_on_test "knowledge-books-link"
    expect(page).to have_current_path(member_knowledge_books_path)
    expect_test "member-knowledge-books"
  end
end
