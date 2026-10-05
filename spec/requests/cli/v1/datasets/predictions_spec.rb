# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Datasets::Predictions", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:, key: "ACME") }
  let(:dataset) { create(:dataset, project:, name: "Cartelli") }

  let!(:foto) { create(:dataset_column, :photo, dataset:, code: "foto", label: "Foto", position: 0) }
  let!(:colore) { create(:dataset_column, dataset:, code: "colore", label: "Colore", role: :input, required: true, position: 1) }
  let!(:esito) { create(:dataset_column, :target, dataset:, code: "esito", label: "Esito", kind: :category, options: %w[ok ko], position: 2) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
  end

  let(:secret) { Accounts::ApiTokens::Issue.call(account: owner, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro assegnato al progetto ma SENZA datasets.train: legge, non chiede previsioni.
  def reader
    @reader ||= begin
      account = create(:account)
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
      account
    end
  end

  def reader_headers
    reader_secret = Accounts::ApiTokens::Issue.call(account: reader, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{reader_secret}" }
  end

  def png
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/screenshot.png"), "image/png")
  end

  it "senza token → 401" do
    post "/cli/v1/datasets/#{dataset.id}/predictions"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "POST create" do
    context "con un addestramento completato" do
      let!(:training) { create(:dataset_training, :done, dataset:) }

      # Scenario 1 del ticket: finito l'addestramento si chiede la previsione sui dati nuovi.
      it "chiede la previsione sui dati nuovi e mette in coda il lavoro" do
        expect do
          post "/cli/v1/datasets/#{dataset.id}/predictions",
               params: { confirm: "1", values: { colore: "rosso" }, photos: { foto: png } }, headers: headers
        end.to change(Datasets::Prediction, :count).by(1).and have_enqueued_job(Datasets::PredictJob)

        expect(response).to have_http_status(:created)
        prediction = Datasets::Prediction.sole
        expect(prediction.training).to eq(training)
        expect(prediction.input_row).to be_purpose_prediction
        expect(prediction.input_row.value_for("colore")).to eq("rosso")
        expect(response.parsed_body["data"]).to include("id" => prediction.id, "status" => "pending",
                                                        "training_id" => training.id)
        expect(response.parsed_body.dig("data", "input_row", "values")).to eq("colore" => "rosso")
        expect(response.parsed_body.dig("data", "input_row", "photos", "foto"))
          .to include("content_type" => "image/png")
      end

      it "usa sempre l'ultimo addestramento riuscito" do
        recente = create(:dataset_training, :done, dataset:, created_at: 1.minute.from_now)

        post "/cli/v1/datasets/#{dataset.id}/predictions",
             params: { confirm: "1", values: { colore: "rosso" } }, headers: headers

        expect(Datasets::Prediction.sole.training).to eq(recente)
      end

      it "le righe di previsione non finiscono fra gli esempi del dataset" do
        post "/cli/v1/datasets/#{dataset.id}/predictions",
             params: { confirm: "1", values: { colore: "rosso" } }, headers: headers

        expect(dataset.rows.purpose_sample).to be_empty
        expect(dataset.rows.purpose_prediction.count).to eq(1)
      end

      it "dato obbligatorio mancante → 422 R422-DATASET-003 coi campi in errore, nessuna previsione" do
        expect do
          post "/cli/v1/datasets/#{dataset.id}/predictions", params: { confirm: "1", values: {} }, headers: headers
        end.not_to change(Datasets::Prediction, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.dig("error", "code")).to eq("R422-DATASET-003")
        expect(response.parsed_body.dig("error", "details")).to include("colore")
      end

      it "il valore del target NON è obbligatorio: è quello che si chiede di predire" do
        expect do
          post "/cli/v1/datasets/#{dataset.id}/predictions",
               params: { confirm: "1", values: { colore: "rosso" } }, headers: headers
        end.to change(Datasets::Prediction, :count).by(1)
      end

      it "valori mandati come testo invece che come mappa → 422, non un errore del server" do
        post "/cli/v1/datasets/#{dataset.id}/predictions", params: { confirm: "1", values: "colore=rosso" }, headers: headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.dig("error", "code")).to eq("R422-DATASET-003")
      end

      it "un file che non è un file → 422, non un errore del server" do
        expect do
          post "/cli/v1/datasets/#{dataset.id}/predictions",
               params: { confirm: "1", values: { colore: "rosso" }, photos: { foto: "screenshot.png" } }, headers: headers
        end.not_to change(Datasets::Prediction, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.dig("error", "code")).to eq("R422-DATASET-003")
      end

      it "membro assegnato senza datasets.train → 403" do
        expect do
          post "/cli/v1/datasets/#{dataset.id}/predictions",
               params: { values: { colore: "rosso" } }, headers: reader_headers
        end.not_to change(Datasets::Prediction, :count)

        expect(response).to have_http_status(:forbidden)
      end

      it "la sola datasets.train basta per chiedere una previsione (senza datasets.manage)" do
        create(:account_permission, account: reader, organization:, permission_key: "datasets.train", effect: :allow)

        expect do
          post "/cli/v1/datasets/#{dataset.id}/predictions",
               params: { confirm: "1", values: { colore: "rosso" } }, headers: reader_headers
        end.to change(Datasets::Prediction, :count).by(1)
      end

      it "dataset non visibile → 404 prima del gate (anti-BOLA)" do
        altrove = create(:dataset, project: create(:project, organization: create(:organization)))

        post "/cli/v1/datasets/#{altrove.id}/predictions", params: { values: {} }, headers: headers

        expect(response).to have_http_status(:not_found)
      end
    end

    it "senza un addestramento completato → 422 R422-DATASET-005, nessuna riga scritta" do
      create(:dataset_training, dataset:, status: :running)

      expect do
        post "/cli/v1/datasets/#{dataset.id}/predictions",
             params: { confirm: "1", values: { colore: "rosso" } }, headers: headers
      end.to not_change(Datasets::Prediction, :count).and not_change(Datasets::Row, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("code" => "R422-DATASET-005",
                                                       "message" => I18n.t("datasets.errors.no_training"))
    end
  end

  describe "GET show" do
    # Definition of Done: il risultato letto da terminale è quello che mostra la pagina.
    it "previsione finita: stato, valori predetti e dati in ingresso" do
      row = create(:dataset_row, :prediction, dataset:, cell_values: { "colore" => "rosso" })
      prediction = create(:dataset_prediction, :done, dataset_record: dataset, input_row: row, created_by: owner)

      get "/cli/v1/datasets/#{dataset.id}/predictions/#{prediction.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include(
        "id" => prediction.id, "status" => "done", "dataset_id" => dataset.id,
        "predicted_values" => { "esito" => "positivo" }, "author" => owner.name
      )
      expect(response.parsed_body.dig("data", "input_row", "values")).to eq("colore" => "rosso")
    end

    it "previsione in corso: stato senza risultato" do
      prediction = create(:dataset_prediction, dataset_record: dataset, status: :running)

      get "/cli/v1/datasets/#{dataset.id}/predictions/#{prediction.id}", headers: headers

      expect(response.parsed_body["data"]).to include("status" => "running", "predicted_values" => {})
    end

    it "previsione fallita: il motivo, com'è scritto sulla pagina" do
      prediction = create(:dataset_prediction, dataset_record: dataset, status: :failed,
                                               error_code: "R502-DATASET-002", error_message: "Risposta illeggibile")

      get "/cli/v1/datasets/#{dataset.id}/predictions/#{prediction.id}", headers: headers

      expect(response.parsed_body["data"]).to include("status" => "failed",
                                                      "error_code" => "R502-DATASET-002",
                                                      "error_message" => "Risposta illeggibile")
    end

    it "membro assegnato senza datasets.train → 200 (leggere è visibilità del progetto)" do
      prediction = create(:dataset_prediction, :done, dataset_record: dataset)

      get "/cli/v1/datasets/#{dataset.id}/predictions/#{prediction.id}", headers: reader_headers

      expect(response).to have_http_status(:ok)
    end

    it "previsione di un dataset non visibile → 404 (anti-BOLA)" do
      altrove = create(:dataset_prediction, :done)

      get "/cli/v1/datasets/#{altrove.dataset_id}/predictions/#{altrove.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET index" do
    it "elenca le previsioni del dataset, dalla più recente" do
      vecchia = create(:dataset_prediction, :done, dataset_record: dataset, created_at: 2.days.ago)
      nuova = create(:dataset_prediction, dataset_record: dataset, created_at: 1.hour.ago)
      create(:dataset_prediction, :done)

      get "/cli/v1/datasets/#{dataset.id}/predictions", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |p| p["id"] }).to eq([ nuova.id, vecchia.id ])
      expect(response.parsed_body["meta"]).to include("total" => 2)
    end

    it "membro assegnato senza datasets.train → 200" do
      create(:dataset_prediction, :done, dataset_record: dataset)

      get "/cli/v1/datasets/#{dataset.id}/predictions", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].length).to eq(1)
    end
  end
end
