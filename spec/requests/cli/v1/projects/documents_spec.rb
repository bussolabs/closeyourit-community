# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Projects::Documents", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account: owner, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro assegnato al progetto ma SENZA documents.manage: legge e scarica, non scrive.
  def reader_headers
    reader = create(:account)
    create(:membership, account: reader, organization:, role: :member)
    create(:project_membership, account: reader, project:)
    reader_secret = Accounts::ApiTokens::Issue.call(account: reader, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{reader_secret}" }
  end

  def upload(name, declared_type)
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/#{name}"), declared_type)
  end

  it "senza token → 401" do
    get "/cli/v1/projects/#{project.id}/documents"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "elenca i documenti con i metadati del file, mai un URL firmato" do
      create(:document, project:, title: "Contratto 2026", tags: %w[legal], created_by: owner)

      get "/cli/v1/projects/#{project.id}/documents", headers: headers

      expect(response).to have_http_status(:ok)
      riga = response.parsed_body["data"].sole
      expect(riga).to include("title" => "Contratto 2026", "tags" => %w[legal],
                              "filename" => "spec.pdf", "content_type" => "application/pdf",
                              "author" => owner.name)
      expect(riga["byte_size"]).to be_positive
      expect(riga.keys).not_to include("url", "signed_id")
    end

    it "member assegnato senza documents.manage → 200 (lettura = visibilità del progetto)" do
      create(:document, project:)

      get "/cli/v1/projects/#{project.id}/documents", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].length).to eq(1)
    end

    it "progetto non visibile → 404 (anti-BOLA)" do
      estraneo = create(:project, organization: create(:organization))

      get "/cli/v1/projects/#{estraneo.id}/documents", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "?q= cerca su nome e sul nome file originale, come il sito" do
      create(:document, project:, title: "Capitolato")
      rinominato = create(:document, project:, title: "Senza nome parlante")
      rinominato.file.attach(io: StringIO.new("%PDF-1.4 fake"), filename: "capitolato-firmato.pdf",
                             content_type: "application/pdf")

      get "/cli/v1/projects/#{project.id}/documents", params: { q: "capitolato" }, headers: headers

      titoli = response.parsed_body["data"].pluck("title")
      expect(titoli).to contain_exactly("Capitolato", "Senza nome parlante")
    end

    it "?tag[]= filtra per tag (overlap), come il sito" do
      create(:document, project:, title: "Contratto", tags: %w[legal q3])
      create(:document, project:, title: "Export", tags: %w[dati])

      get "/cli/v1/projects/#{project.id}/documents", params: { tag: [ "legal" ] }, headers: headers

      expect(response.parsed_body["data"].pluck("title")).to eq([ "Contratto" ])
    end
  end

  describe "GET show" do
    it "ritorna i metadati del documento" do
      document = create(:document, project:, title: "Capitolato", description: "Bozza")

      get "/cli/v1/projects/#{project.id}/documents/#{document.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include("title" => "Capitolato", "description" => "Bozza")
    end

    it "documento di un altro progetto → 404 (anti-BOLA)" do
      altrove = create(:document, project: create(:project, organization:))

      get "/cli/v1/projects/#{project.id}/documents/#{altrove.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    it "carica un file con nome, descrizione e tag e lo registra in cronologia" do
      expect do
        post "/cli/v1/projects/#{project.id}/documents",
             params: { file: upload("notes.txt", "text/plain"), title: "Verbale",
                       description: "Riunione di ottobre", tags: "legal, q3" },
             headers: headers
      end.to change(Projects::Document, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("title" => "Verbale", "tags" => %w[legal q3],
                                                      "filename" => "notes.txt")
      document = Projects::Document.sole
      expect(document.description).to eq("Riunione di ottobre")
      expect(document.created_by).to eq(owner)
      expect(document.activity_events.pluck(:action)).to eq([ "created" ])
    end

    it "senza title usa il nome del file, come il sito" do
      post "/cli/v1/projects/#{project.id}/documents",
           params: { file: upload("notes.txt", "text/plain") }, headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["title"]).to eq("notes.txt")
    end

    it "accetta i tag anche come lista" do
      post "/cli/v1/projects/#{project.id}/documents",
           params: { file: upload("notes.txt", "text/plain"), tags: %w[Legal legal q3] }, headers: headers

      expect(response.parsed_body["data"]["tags"]).to eq(%w[legal q3])
    end

    it "senza file → R422-DOCUMENT-001" do
      post "/cli/v1/projects/#{project.id}/documents", params: { title: "Vuoto" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-DOCUMENT-001")
    end

    it "rifiuta un file travestito, sniffando i byte reali" do
      expect do
        post "/cli/v1/projects/#{project.id}/documents",
             params: { file: upload("payload.html", "image/png") }, headers: headers
      end.not_to change(Projects::Document, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-DOCUMENT-001")
    end

    it "un file che non è un file (parametro di testo) → R422-DOCUMENT-001, non un errore del server" do
      post "/cli/v1/projects/#{project.id}/documents", params: { file: "notes.txt" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-DOCUMENT-001")
      expect(Projects::Document.count).to eq(0)
    end

    it "senza documents.manage → 403" do
      expect do
        post "/cli/v1/projects/#{project.id}/documents",
             params: { file: upload("notes.txt", "text/plain") }, headers: reader_headers
      end.not_to change(Projects::Document, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-CLIAUTH-002")
    end
  end

  describe "PATCH update" do
    let!(:document) { create(:document, project:, title: "Bozza", description: "Vecchia", tags: %w[legal]) }

    it "rinomina, ritagga e resta in cronologia" do
      patch "/cli/v1/projects/#{project.id}/documents/#{document.id}",
            params: { title: "Contratto firmato", tags: "legal, firmato" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(document.reload.title).to eq("Contratto firmato")
      expect(document.tags).to eq(%w[legal firmato])
      expect(document.activity_events.pluck(:action)).to eq([ "updated" ])
    end

    it "modifica parziale: i campi non inviati restano" do
      patch "/cli/v1/projects/#{project.id}/documents/#{document.id}",
            params: { tags: "q3" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(document.reload.title).to eq("Bozza")
      expect(document.description).to eq("Vecchia")
      expect(document.tags).to eq([ "q3" ])
    end

    it "titolo vuoto → R422-DOCUMENT-002" do
      patch "/cli/v1/projects/#{project.id}/documents/#{document.id}",
            params: { title: "  " }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-DOCUMENT-002")
      expect(document.reload.title).to eq("Bozza")
    end

    it "senza documents.manage → 403, documento intatto" do
      patch "/cli/v1/projects/#{project.id}/documents/#{document.id}",
            params: { title: "Mio" }, headers: reader_headers

      expect(response).to have_http_status(:forbidden)
      expect(document.reload.title).to eq("Bozza")
    end
  end

  describe "GET download" do
    let!(:document) do
      Projects::Documents::Upload.call(project:, files: [ upload("notes.txt", "text/plain") ],
                                       actor: owner).value.first
    end

    it "consegna il binario come file da salvare, anche a chi non lo gestisce" do
      get "/cli/v1/projects/#{project.id}/documents/#{document.id}/download", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("application/octet-stream")
      expect(response.headers["Content-Disposition"]).to start_with("attachment")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.headers["Content-Disposition"]).to include("notes.txt")
      expect(response.body).to eq(File.read(Rails.root.join("spec/fixtures/files/notes.txt")))
    end

    it "documento di un altro progetto → 404 (anti-BOLA)" do
      altrove = create(:document, project: create(:project, organization:))

      get "/cli/v1/projects/#{project.id}/documents/#{altrove.id}/download", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    let!(:document) { create(:document, project:) }

    it "elimina e risponde 204" do
      expect do
        delete "/cli/v1/projects/#{project.id}/documents/#{document.id}", headers: headers
      end.to change(Projects::Document, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "senza documents.manage → 403, documento intatto" do
      expect do
        delete "/cli/v1/projects/#{project.id}/documents/#{document.id}", headers: reader_headers
      end.not_to change(Projects::Document, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
