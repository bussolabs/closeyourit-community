# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Knowledge::Books", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET /member/knowledge/books" do
    it "risponde con 200 e mostra i book dei progetti visibili" do
      create(:knowledge_book, organization: org, project: project, title: "Manuale onboarding")
      sign_in(member)

      get member_knowledge_books_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Manuale onboarding")
      expect(response.body).to include("data-test=\"knowledge-books-counts\"")
    end

    it "esclude i book dei progetti non visibili (scoping)" do
      hidden_project = create(:project, organization: org, name: "Progetto riservato")
      create(:knowledge_book, organization: org, project: hidden_project, title: "Libro segreto")
      sign_in(member)

      get member_knowledge_books_path
      expect(response.body).not_to include("Libro segreto")
    end
  end

  describe "GET /member/knowledge/books/:id" do
    it "mostra il TOC delle pagine e il contenuto della prima pagina (Outline)" do
      book = create(:knowledge_book, organization: org, project: project, title: "Guida")
      first = create(:knowledge_page, organization: org, project: project, book: book, position: 0,
                                      title: "Introduzione", body: "## Benvenuto\n\nTesto uno.")
      second = create(:knowledge_page, organization: org, project: project, book: book, position: 1,
                                       title: "Capitolo due", body: "## Due\n\nTesto due.")
      sign_in(member)

      get member_knowledge_book_path(book)
      expect(response).to have_http_status(:ok)
      # TOC: entrambe le pagine come voci d'indice.
      expect(response.body).to include("Introduzione")
      expect(response.body).to include("Capitolo due")
      # Contenuto a destra: la prima pagina resa in markdown, con la voce attiva evidenziata.
      expect(response.body).to include("Benvenuto</h2>")
      active = Nokogiri::HTML(response.body).at_css("[data-test=\"knowledge-book-toc-link-#{first.id}\"]")
      expect(active["aria-current"]).to eq("page")
      inactive = Nokogiri::HTML(response.body).at_css("[data-test=\"knowledge-book-toc-link-#{second.id}\"]")
      expect(inactive["aria-current"]).to be_nil
    end

    it "con page_id seleziona la pagina indicata e ne mostra il contenuto" do
      book = create(:knowledge_book, organization: org, project: project)
      create(:knowledge_page, organization: org, project: project, book: book, position: 0, title: "Prima", body: "uno")
      target = create(:knowledge_page, organization: org, project: project, book: book, position: 1,
                                       title: "Seconda", body: "## Scelta\n\nContenuto due.")
      sign_in(member)

      get member_knowledge_book_path(book, page_id: target.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Scelta</h2>")
      active = Nokogiri::HTML(response.body).at_css("[data-test=\"knowledge-book-toc-link-#{target.id}\"]")
      expect(active["aria-current"]).to eq("page")
    end

    it "un page_id di una pagina non nel book ricade sulla prima pagina" do
      book = create(:knowledge_book, organization: org, project: project)
      first = create(:knowledge_page, organization: org, project: project, book: book, position: 0, title: "Prima", body: "## Uno\n\ntesto")
      foreign = create(:knowledge_page, organization: org, project: project, title: "Fuori")
      sign_in(member)

      get member_knowledge_book_path(book, page_id: foreign.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Uno</h2>")
      expect(Nokogiri::HTML(response.body).at_css("[data-test=\"knowledge-book-toc-link-#{first.id}\"]")["aria-current"]).to eq("page")
    end

    it "book vuoto: mostra lo stato vuoto senza crash" do
      book = create(:knowledge_book, organization: org, project: project)
      sign_in(member)

      get member_knowledge_book_path(book)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"knowledge-book-empty\"")
      # Il vuoto si dice una volta sola: niente indice laterale che ripete «nessuna pagina».
      expect(response.body).not_to include("data-test=\"knowledge-book-toc\"")
    end

    it "book di progetto non visibile → 404 (anti-BOLA)" do
      hidden = create(:knowledge_book, organization: org, project: create(:project, organization: org))
      sign_in(member)

      get member_knowledge_book_path(hidden)
      expect(response).to have_http_status(:not_found)
    end

    it "con accesso parziale mostra solo pagine e collegamenti dei progetti visibili" do
      # Nome ESPLICITO e distinto: con nomi Faker casuali il nome del progetto visibile poteva
      # coincidere con quello nascosto → l'asserzione sullo scope-label falliva a caso (CYRA-143).
      hidden_project = create(:project, organization: org, name: "Progetto riservato")
      book = create(:knowledge_book, organization: org, project: project, title: "Book condiviso")
      book.projects << hidden_project
      visible_page = create(:knowledge_page, organization: org, project: project, book: book, title: "Visibile")
      hidden_page = create(:knowledge_page, organization: org, project: hidden_project, book: book, title: "Riservata")
      sign_in(member)

      get member_knowledge_book_path(book)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(visible_page.title)
      expect(response.body).not_to include(hidden_page.title)
      scope_labels = Nokogiri::HTML(response.body).css("[data-test='knowledge-book-scope'] span").map { |node| node.text.strip }
      expect(scope_labels).not_to include(hidden_project.name)
      expect(response.body).not_to include('data-test="knowledge-book-edit"')
    end

    it "con accesso parziale non consente la modifica anche all'autore" do
      hidden_project = create(:project, organization: org)
      book = create(:knowledge_book, organization: org, project: project, created_by: member)
      book.projects << hidden_project
      sign_in(member)

      get edit_member_knowledge_book_path(book)

      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET new + POST create" do
    it "new risponde con 200" do
      sign_in(member)
      get new_member_knowledge_book_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"knowledge-book-form\"")
    end

    it "crea un book (baseline di chi vede lo scope) e reindirizza alla show" do
      sign_in(member)
      expect {
        post member_knowledge_books_path, params: { project_id: project.id, title: "Nuovo libro", description: "d" }
      }.to change(Knowledge::Book, :count).by(1)

      book = Knowledge::Book.find_by(title: "Nuovo libro")
      expect(book.created_by).to eq(member)
      expect(response).to redirect_to(member_knowledge_book_path(book))
    end

    it "titolo vuoto: ri-renderizza il form con 422" do
      sign_in(member)
      post member_knowledge_books_path, params: { project_id: project.id, title: "" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("data-test=\"knowledge-book-form\"")
    end

    it "titolo vuoto mantiene progetti e gruppi selezionati nel form" do
      group = create(:group, organization: org)
      sign_in(owner)

      post member_knowledge_books_path,
           params: { project_ids: [ project.id ], group_ids: [ group.id ], title: "" }

      document = Nokogiri::HTML(response.body)
      expect(document.at_css("[data-test='knowledge-book-form-projects'] option[value='#{project.id}']")
                     .key?("selected")).to be(true)
      expect(document.at_css("[data-test='knowledge-book-form-groups'] option[value='#{group.id}']")
                     .key?("selected")).to be(true)
    end
  end

  describe "PATCH update (assegnazione pagine)" do
    it "l'autore aggiorna il titolo e assegna le pagine in ordine" do
      book = create(:knowledge_book, organization: org, project: project, title: "Vecchio", created_by: member)
      page_a = create(:knowledge_page, organization: org, project: project, title: "A")
      page_b = create(:knowledge_page, organization: org, project: project, title: "B")
      sign_in(member)

      patch member_knowledge_book_path(book),
            params: { title: "Aggiornato", description: "x", page_ids: [ page_b.id, page_a.id ] }

      expect(response).to redirect_to(member_knowledge_book_path(book))
      expect(book.reload.title).to eq("Aggiornato")
      expect(page_b.reload.book_id).to eq(book.id)
      expect(page_b.position).to eq(0)
      expect(page_a.reload.position).to eq(1)
    end
  end

  describe "DELETE destroy" do
    it "l'autore elimina il book e le pagine sopravvivono orfane" do
      book = create(:knowledge_book, organization: org, project: project, created_by: member)
      page = create(:knowledge_page, organization: org, project: project, book: book)
      sign_in(member)

      expect {
        delete member_knowledge_book_path(book)
      }.to change(Knowledge::Book, :count).by(-1)
      expect(response).to redirect_to(member_knowledge_books_path)
      expect(page.reload.book_id).to be_nil
    end
  end

  describe "RBAC — gestione book altrui" do
    let!(:others_book) { create(:knowledge_book, organization: org, project: project, created_by: owner) }

    it "un membro senza knowledge.edit non può modificare il book altrui (redirect)" do
      sign_in(member)
      get edit_member_knowledge_book_path(others_book)
      expect(response).to redirect_to(root_path)
    end

    it "un membro senza knowledge.delete non può eliminare il book altrui (redirect, book intatto)" do
      sign_in(member)
      expect {
        delete member_knowledge_book_path(others_book)
      }.not_to change(Knowledge::Book, :count)
      expect(response).to redirect_to(root_path)
    end

    it "l'autore vede il proprio edit (200)" do
      own = create(:knowledge_book, organization: org, project: project, created_by: member)
      sign_in(member)
      get edit_member_knowledge_book_path(own)
      expect(response).to have_http_status(:ok)
    end
  end
end
