# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Datasets::Rows", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:, key: "ACME") }
  let(:dataset) { create(:dataset, project:, name: "Cartelli") }

  let!(:foto) { create(:dataset_column, :photo, dataset:, code: "foto", label: "Foto", position: 0) }
  let!(:colore) { create(:dataset_column, dataset:, code: "colore", label: "Colore", role: :input, required: true, position: 1) }
  let!(:esito) { create(:dataset_column, :target, dataset:, code: "esito", label: "Esito", position: 2) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account: owner, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def reader_headers
    reader = create(:account)
    create(:membership, account: reader, organization:, role: :member)
    create(:project_membership, account: reader, project:)
    reader_secret = Accounts::ApiTokens::Issue.call(account: reader, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{reader_secret}" }
  end

  def png
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/screenshot.png"), "image/png")
  end

  it "senza token → 401" do
    get "/cli/v1/datasets/#{dataset.id}/rows"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "elenca le righe con i valori e i metadati delle foto, mai un URL firmato" do
      row = create(:dataset_row, dataset:, cell_values: { "colore" => "rosso", "esito" => "ok" })
      create(:dataset_cell, row:, column: foto)

      get "/cli/v1/datasets/#{dataset.id}/rows", headers: headers

      expect(response).to have_http_status(:ok)
      riga = response.parsed_body["data"].sole
      expect(riga).to include("id" => row.id, "purpose" => "sample",
                              "values" => { "colore" => "rosso", "esito" => "ok" })
      expect(riga["photos"]["foto"]).to include("filename" => "cell.png", "content_type" => "image/png")
      expect(riga["photos"]["foto"]["byte_size"]).to be_positive
      expect(riga.to_s).not_to include("signed_id")
    end

    it "member assegnato senza datasets.manage → 200 (lettura = visibilità del progetto)" do
      create(:dataset_row, dataset:)

      get "/cli/v1/datasets/#{dataset.id}/rows", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].length).to eq(1)
    end

    it "dataset non visibile → 404 (anti-BOLA)" do
      altrove = create(:dataset, project: create(:project, organization: create(:organization)))

      get "/cli/v1/datasets/#{altrove.id}/rows", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    it "aggiunge una riga con i valori scalari" do
      expect do
        post "/cli/v1/datasets/#{dataset.id}/rows",
             params: { values: { colore: "rosso", esito: "ok" } }, headers: headers
      end.to change(Datasets::Row, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["values"]).to eq("colore" => "rosso", "esito" => "ok")
      expect(Datasets::Row.sole.cell_values).to eq("colore" => "rosso", "esito" => "ok")
    end

    # Scenario 2 del ticket: la riga si salva con la foto allegata, e la foto è quella.
    it "aggiunge una riga con la foto allegata (multipart)" do
      expect do
        post "/cli/v1/datasets/#{dataset.id}/rows",
             params: { values: { colore: "rosso", esito: "ok" }, photos: { foto: png } }, headers: headers
      end.to change(Datasets::Cell, :count).by(1)

      expect(response).to have_http_status(:created)
      cella = Datasets::Cell.sole
      expect(cella.column).to eq(foto)
      expect(cella.image).to be_attached
      expect(response.parsed_body["data"]["photos"]["foto"]).to include("content_type" => "image/png")
    end

    it "campo obbligatorio mancante → 422 R422-DATASET-003 coi campi in errore" do
      expect do
        post "/cli/v1/datasets/#{dataset.id}/rows", params: { values: { esito: "ok" } }, headers: headers
      end.not_to change(Datasets::Row, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-DATASET-003")
      expect(response.parsed_body.dig("error", "details")).to include("colore")
    end

    it "un file che non è un file (parametro di testo) → 422, non un errore del server" do
      expect do
        post "/cli/v1/datasets/#{dataset.id}/rows",
             params: { values: { colore: "rosso", esito: "ok" }, photos: { foto: "screenshot.png" } },
             headers: headers
      end.not_to change(Datasets::Row, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-DATASET-003")
    end

    it "valori mandati come testo invece che come mappa → 422, non un errore del server" do
      post "/cli/v1/datasets/#{dataset.id}/rows", params: { values: "colore=rosso" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-DATASET-003")
    end

    it "un file travestito da immagine → 422 (tipo sniffato sui byte reali)" do
      travestito = Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/payload.html"), "image/png")

      expect do
        post "/cli/v1/datasets/#{dataset.id}/rows",
             params: { values: { colore: "rosso", esito: "ok" }, photos: { foto: travestito } }, headers: headers
      end.not_to change(Datasets::Cell, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "senza datasets.manage → 403" do
      expect do
        post "/cli/v1/datasets/#{dataset.id}/rows",
             params: { values: { colore: "rosso", esito: "ok" } }, headers: reader_headers
      end.not_to change(Datasets::Row, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-CLIAUTH-002")
    end
  end

  describe "PATCH update" do
    let(:row) { create(:dataset_row, dataset:, cell_values: { "colore" => "rosso", "esito" => "ok" }) }

    it "cambia solo i valori presenti e lascia gli altri dov'erano" do
      patch "/cli/v1/datasets/#{dataset.id}/rows/#{row.id}", params: { values: { esito: "ko" } }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(row.reload.cell_values).to eq("colore" => "rosso", "esito" => "ko")
    end

    it "sostituisce la foto inviata e non tocca le altre celle" do
      create(:dataset_cell, row:, column: foto)
      vecchio = foto.cells.sole.image.blob.id

      patch "/cli/v1/datasets/#{dataset.id}/rows/#{row.id}", params: { photos: { foto: png } }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(row.reload.cells.sole.image.blob.id).not_to eq(vecchio)
      expect(row.cell_values).to eq("colore" => "rosso", "esito" => "ok")
    end

    it "riga di un altro dataset → 404 (anti-BOLA)" do
      altrove = create(:dataset_row, dataset: create(:dataset, project:))

      patch "/cli/v1/datasets/#{dataset.id}/rows/#{altrove.id}", params: { values: { esito: "ko" } }, headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "senza datasets.manage → 403" do
      patch "/cli/v1/datasets/#{dataset.id}/rows/#{row.id}", params: { values: { esito: "ko" } },
                                                             headers: reader_headers

      expect(response).to have_http_status(:forbidden)
      expect(row.reload.cell_values).to include("esito" => "ok")
    end
  end

  describe "DELETE destroy" do
    it "elimina la riga" do
      row = create(:dataset_row, dataset:)

      expect { delete "/cli/v1/datasets/#{dataset.id}/rows/#{row.id}", headers: headers }
        .to change(Datasets::Row, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "senza datasets.manage → 403" do
      row = create(:dataset_row, dataset:)

      expect { delete "/cli/v1/datasets/#{dataset.id}/rows/#{row.id}", headers: reader_headers }
        .not_to change(Datasets::Row, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET photo" do
    it "consegna il binario come file da salvare, mai come pagina" do
      row = create(:dataset_row, dataset:)
      create(:dataset_cell, row:, column: foto)

      get "/cli/v1/datasets/#{dataset.id}/rows/#{row.id}/photos/foto", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("application/octet-stream")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.body.bytesize).to be_positive
    end

    it "colonna senza foto → 404" do
      row = create(:dataset_row, dataset:)

      get "/cli/v1/datasets/#{dataset.id}/rows/#{row.id}/photos/foto", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "codice di colonna inesistente → 404" do
      row = create(:dataset_row, dataset:)

      get "/cli/v1/datasets/#{dataset.id}/rows/#{row.id}/photos/inesistente", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  # Scenario 1 e 2 del ticket: la riga aggiunta da terminale, foto compresa, è quella che si apre
  # sul sito — non una copia che le somiglia.
  describe "parità col canale web" do
    it "la riga con foto aggiunta da terminale compare nella scheda del dataset sul sito" do
      post "/cli/v1/datasets/#{dataset.id}/rows",
           params: { values: { colore: "rosso", esito: "ok" }, photos: { foto: png } }, headers: headers

      post login_path, params: { email: owner.email, password: "Secret123!" }
      get member_dataset_path(dataset)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("rosso")
      expect(Datasets::Cell.sole.image).to be_attached
    end
  end
end
