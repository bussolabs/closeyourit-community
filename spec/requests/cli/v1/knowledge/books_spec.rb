# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Knowledge::Books", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro che VEDE il progetto (quindi il book) ma senza chiavi knowledge.* → testa il 403 sull'add-page.
  def member_context
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { account: member, headers: { "Authorization" => "Bearer #{member_secret}" } }
  end

  def book_with(project_scope)
    create(:knowledge_book, organization:, project: project_scope)
  end

  it "senza token → 401" do
    get "/cli/v1/knowledge/books"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET /cli/v1/knowledge/books" do
    it "elenca i book visibili con meta (0/1/N) e i conteggi pagine scoped" do
      book = create(:knowledge_book, organization:, project:, created_by: account)
      create(:knowledge_page, organization:, project:, book:)
      create(:knowledge_page, organization:, project:, book:)
      book_with(project)

      get "/cli/v1/knowledge/books", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].size).to eq(2)
      expect(response.parsed_body["meta"]).to include("total" => 2)
      row = response.parsed_body["data"].find { |b| b["id"] == book.id }
      expect(row).to include("title" => book.title, "author" => account.name, "pages_count" => 2)
      expect(row["projects"]).to eq([ project.key ])
    end

    it "filtra per progetto (key) e per titolo (?q=)" do
      other = create(:project, organization:)
      keep = create(:knowledge_book, organization:, project:, title: "Manuale deploy")
      book_with(other)

      get "/cli/v1/knowledge/books", params: { project: project.key.downcase }, headers: headers
      expect(response.parsed_body["data"].map { |b| b["id"] }).to eq([ keep.id ])

      get "/cli/v1/knowledge/books", params: { q: "deploy" }, headers: headers
      expect(response.parsed_body["data"].map { |b| b["id"] }).to eq([ keep.id ])
    end

    it "esclude i book dei progetti non visibili (anti-BOLA) e 404 sul filtro progetto fuori scope" do
      ctx = member_context
      inside = book_with(project)
      hidden = book_with(create(:project, organization:))

      get "/cli/v1/knowledge/books", headers: ctx[:headers]
      ids = response.parsed_body["data"].map { |b| b["id"] }
      expect(ids).to include(inside.id)
      expect(ids).not_to include(hidden.id)

      get "/cli/v1/knowledge/books", params: { project: hidden.projects.first.key }, headers: ctx[:headers]
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /cli/v1/knowledge/books/:id" do
    it "mostra il book col sommario ordinato (TOC) e riferimenti umani" do
      book = book_with(project)
      first  = create(:knowledge_page, organization:, project:, book:, position: 0, title: "Intro")
      second = create(:knowledge_page, organization:, project:, book:, position: 1, title: "Setup")

      get "/cli/v1/knowledge/books/#{book.id}", headers: headers
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to include("id" => book.id, "pages_count" => 2)
      expect(data["pages"].map { |p| p["id"] }).to eq([ first.id, second.id ])
      expect(data["pages"].first).to include("title" => "Intro", "position" => 0, "project" => project.key)
      expect(data["pages"].first).not_to have_key("body")
    end

    it "book senza pagine → sommario vuoto (caso 0)" do
      book = book_with(project)
      get "/cli/v1/knowledge/books/#{book.id}", headers: headers
      expect(response.parsed_body["data"]).to include("pages" => [], "pages_count" => 0)
    end

    it "book fuori scope → 404" do
      get "/cli/v1/knowledge/books/#{create(:knowledge_book).id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "ANTI-LEAK: nel sommario non compaiono le pagine dei progetti non visibili al lettore" do
      ctx = member_context
      hidden_project = create(:project, organization:)
      book = create(:knowledge_book, organization:, project:)
      book.projects << hidden_project
      visible_page = create(:knowledge_page, organization:, project:, book:, title: "Visibile")
      create(:knowledge_page, organization:, project: hidden_project, book:, title: "Nascosta")

      get "/cli/v1/knowledge/books/#{book.id}", headers: ctx[:headers]
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["pages"].map { |p| p["id"] }).to eq([ visible_page.id ])
      # Anche le key dei progetti fuori vista non trapelano nei metadati del book.
      expect(response.parsed_body["data"]["projects"]).to eq([ project.key ])
    end
      it "ANTI-LEAK: di una pagina multi-progetto il sommario mostra solo un progetto visibile" do
      # La RIGA e' legittimamente visibile (la pagina sta anche su un progetto che vedo), ma il campo
      # `project` non deve rivelare la key di quello nascosto: `page.project` e' uno shim che
      # restituisce il primo progetto in assoluto, non il primo visibile.
      ctx = member_context
      hidden_project = create(:project, organization:, key: "HIDN")
      book = create(:knowledge_book, organization:, project:)
      book.projects << hidden_project
      multi = create(:knowledge_page, organization:, project: hidden_project, book:, title: "Condivisa")
      multi.projects << project

      get "/cli/v1/knowledge/books/#{book.id}", headers: ctx[:headers]

      expect(response).to have_http_status(:ok)
      riga = response.parsed_body["data"]["pages"].sole
      expect(riga["id"]).to eq(multi.id)
      expect(riga["project"]).to eq(project.key)
      expect(response.body).not_to include("HIDN")
    end
  end

  describe "POST /cli/v1/knowledge/books/:id/pages (add-page)" do
    it "aggiunge una pagina in fondo e restituisce il sommario aggiornato" do
      book = book_with(project)
      page = create(:knowledge_page, organization:, project:, title: "Nuova")

      post "/cli/v1/knowledge/books/#{book.id}/pages", params: { page_id: page.id }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["pages"].map { |p| p["id"] }).to eq([ page.id ])
      expect(page.reload.book_id).to eq(book.id)
    end

    it "rispetta la posizione richiesta (0-based) inserendo tra le pagine esistenti" do
      book = book_with(project)
      a = create(:knowledge_page, organization:, project:, book:, position: 0, title: "A")
      b = create(:knowledge_page, organization:, project:, book:, position: 1, title: "B")
      free = create(:knowledge_page, organization:, project:, title: "C")

      post "/cli/v1/knowledge/books/#{book.id}/pages",
           params: { page_id: free.id, position: 1 }, headers: headers
      expect(response.parsed_body["data"]["pages"].map { |p| p["id"] }).to eq([ a.id, free.id, b.id ])
    end

    it "è idempotente: ripetere la stessa aggiunta non duplica la pagina nel sommario" do
      book = book_with(project)
      page = create(:knowledge_page, organization:, project:, title: "Ripetuta")

      post "/cli/v1/knowledge/books/#{book.id}/pages",
           params: { page_id: page.id, position: 0 }, headers: headers
      # Secondo giro identico: le query per-richiesta si ripetono (non è un N+1 di produzione).
      allow_n_plus_one do
        post "/cli/v1/knowledge/books/#{book.id}/pages",
             params: { page_id: page.id, position: 0 }, headers: headers
      end
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["pages"].map { |p| p["id"] }).to eq([ page.id ])
      expect(book.pages.count).to eq(1)
    end

    it "pagina di un progetto non incluso nel book → 422 (resta inaccessibile)" do
      book = book_with(project)
      other_page = create(:knowledge_page, organization:, project: create(:project, organization:), title: "Altrove")

      post "/cli/v1/knowledge/books/#{book.id}/pages", params: { page_id: other_page.id }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-KNOWLEDGE-006")
      expect(other_page.reload.book_id).to be_nil
    end

    it "pagina assente/fuori scope → 404" do
      book = book_with(project)
      post "/cli/v1/knowledge/books/#{book.id}/pages",
           params: { page_id: create(:knowledge_page).id }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "book fuori scope → 404 (anti-BOLA)" do
      page = create(:knowledge_page, organization:, project:)
      post "/cli/v1/knowledge/books/#{create(:knowledge_book).id}/pages",
           params: { page_id: page.id }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "l'autore di un book con progetti fuori dalla sua vista non può add-page (serve full scope)" do
      ctx = member_context
      book = create(:knowledge_book, organization:, created_by: ctx[:account], project:)
      book.projects << create(:project, organization:)
      book.save!
      page = create(:knowledge_page, organization:, project:, title: "X")

      post "/cli/v1/knowledge/books/#{book.id}/pages", params: { page_id: page.id }, headers: ctx[:headers]
      expect(response).to have_http_status(:forbidden)
      expect(page.reload.book_id).to be_nil
    end

    it "membro senza knowledge.edit → 403; owner → ok" do
      book = book_with(project)
      page = create(:knowledge_page, organization:, project:, title: "Da aggiungere")
      ctx = member_context

      post "/cli/v1/knowledge/books/#{book.id}/pages", params: { page_id: page.id }, headers: ctx[:headers]
      expect(response).to have_http_status(:forbidden)
      expect(page.reload.book_id).to be_nil

      post "/cli/v1/knowledge/books/#{book.id}/pages", params: { page_id: page.id }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(page.reload.book_id).to eq(book.id)
    end
  end
end
