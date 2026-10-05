# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Datasets::Trainings", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:, key: "ACME") }
  let(:dataset) { create(:dataset, project:, name: "Cartelli") }

  let!(:foto) { create(:dataset_column, :photo, dataset:, code: "foto", label: "Foto", position: 0) }
  let!(:esito) { create(:dataset_column, :target, dataset:, code: "esito", label: "Esito", kind: :category, options: %w[ok ko], position: 1) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
  end

  let(:secret) { Accounts::ApiTokens::Issue.call(account: owner, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro assegnato al progetto ma SENZA datasets.train: legge, non allena.
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

  def add_sample_rows(count)
    count.times { create(:dataset_row, dataset:, purpose: :sample, cell_values: { "esito" => "ok" }) }
  end

  it "senza token → 401" do
    post "/cli/v1/datasets/#{dataset.id}/trainings"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "POST create" do
    # Scenario 1 del ticket: l'addestramento parte da terminale e si mette in coda, come dal sito.
    it "avvia l'addestramento e mette in coda il lavoro" do
      add_sample_rows(3)

      expect do
        post "/cli/v1/datasets/#{dataset.id}/trainings", params: { confirm: "1" }, headers: headers
      end.to change(Datasets::Training, :count).by(1).and have_enqueued_job(Datasets::TrainJob)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("status" => "pending", "dataset_id" => dataset.id,
                                                      "id" => Datasets::Training.sole.id)
    end

    # Scenario 2 del ticket: nessun secondo addestramento, nessun costo doppio.
    it "addestramento già in corso → 409 R409-DATASET-001 e nessun secondo addestramento" do
      create(:dataset_training, dataset:, status: :pending)
      add_sample_rows(3)

      expect do
        post "/cli/v1/datasets/#{dataset.id}/trainings", params: { confirm: "1" }, headers: headers
      end.not_to have_enqueued_job(Datasets::TrainJob)

      expect(Datasets::Training.count).to eq(1)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body.dig("error", "code")).to eq("R409-DATASET-001")
    end

    # CYRA-791: da terminale il recupero è lo stesso — si riprova e l'addestramento morto col
    # processo viene chiuso come interrotto invece di bloccare per sempre la corsia del dataset.
    it "addestramento interrotto oltre la soglia → il nuovo avvio da terminale riparte" do
      interrotto = create(:dataset_training, dataset:, status: :running,
                                             heartbeat_at: (Datasets::Constants::TRAINING_STALE_AFTER + 1.minute).ago)
      add_sample_rows(3)

      expect do
        post "/cli/v1/datasets/#{dataset.id}/trainings", params: { confirm: "1" }, headers: headers
      end.to change(Datasets::Training, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(interrotto.reload).to be_status_failed
      expect(interrotto.error_code).to eq("R500-DATASET-001")
    end

    it "addestramento già in corso avviato dal sito → rifiutato anche da terminale (stessa corsia)" do
      create(:dataset_training, dataset:, status: :running)
      add_sample_rows(3)

      expect { post "/cli/v1/datasets/#{dataset.id}/trainings", params: { confirm: "1" }, headers: headers }
        .not_to change(Datasets::Training, :count)

      expect(response).to have_http_status(:conflict)
    end

    it "un addestramento concluso non blocca il successivo" do
      create(:dataset_training, :done, dataset:)
      add_sample_rows(3)

      expect { post "/cli/v1/datasets/#{dataset.id}/trainings", params: { confirm: "1" }, headers: headers }
        .to change(Datasets::Training, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it "un addestramento in corso su un ALTRO dataset non blocca questo" do
      create(:dataset_training, status: :pending)
      add_sample_rows(3)

      expect { post "/cli/v1/datasets/#{dataset.id}/trainings", params: { confirm: "1" }, headers: headers }
        .to change(Datasets::Training, :count).by(1)
    end

    it "righe di esempio insufficienti → 422 R422-DATASET-004 col motivo" do
      add_sample_rows(1)

      expect { post "/cli/v1/datasets/#{dataset.id}/trainings", params: { confirm: "1" }, headers: headers }
        .not_to change(Datasets::Training, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("code" => "R422-DATASET-004",
                                                       "message" => I18n.t("datasets.errors.not_enough"))
    end

    it "membro assegnato senza datasets.train → 403" do
      add_sample_rows(3)

      expect { post "/cli/v1/datasets/#{dataset.id}/trainings", headers: reader_headers }
        .not_to change(Datasets::Training, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "la sola datasets.manage NON basta per allenare: il gate è datasets.train" do
      create(:account_permission, account: reader, organization:, permission_key: "datasets.manage", effect: :allow)
      add_sample_rows(3)

      expect { post "/cli/v1/datasets/#{dataset.id}/trainings", headers: reader_headers }
        .not_to change(Datasets::Training, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "la sola datasets.train basta per allenare (senza datasets.manage)" do
      create(:account_permission, account: reader, organization:, permission_key: "datasets.train", effect: :allow)
      add_sample_rows(3)

      expect { post "/cli/v1/datasets/#{dataset.id}/trainings", params: { confirm: "1" }, headers: reader_headers }
        .to change(Datasets::Training, :count).by(1)
    end

    it "dataset non visibile → 404 prima del gate (anti-BOLA)" do
      altrove = create(:dataset, project: create(:project, organization: create(:organization)))

      post "/cli/v1/datasets/#{altrove.id}/trainings", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET show" do
    # Definition of Done: lo stato e il risultato letti da terminale sono quelli che mostra il sito.
    it "addestramento finito: stato, accuratezza, accuratezza per target e prompt" do
      training = create(:dataset_training, :done, dataset:, created_by: owner)

      get "/cli/v1/datasets/#{dataset.id}/trainings/#{training.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include(
        "id" => training.id, "status" => "done", "accuracy" => 0.9,
        "per_target" => { "esito" => 0.9 }, "system_prompt" => training.system_prompt,
        "author" => owner.name
      )
    end

    it "addestramento in corso: stato senza risultato" do
      training = create(:dataset_training, dataset:, status: :running)

      get "/cli/v1/datasets/#{dataset.id}/trainings/#{training.id}", headers: headers

      expect(response.parsed_body["data"]).to include("status" => "running", "accuracy" => nil,
                                                      "system_prompt" => nil)
    end

    it "addestramento fallito: il motivo, com'è scritto sulla pagina" do
      training = create(:dataset_training, :failed, dataset:)

      get "/cli/v1/datasets/#{dataset.id}/trainings/#{training.id}", headers: headers

      expect(response.parsed_body["data"]).to include("status" => "failed",
                                                      "error_code" => "R502-DATASET-001",
                                                      "error_message" => "Gateway non disponibile")
    end

    it "membro assegnato senza datasets.train → 200 (leggere è visibilità del progetto)" do
      training = create(:dataset_training, :done, dataset:)

      get "/cli/v1/datasets/#{dataset.id}/trainings/#{training.id}", headers: reader_headers

      expect(response).to have_http_status(:ok)
    end

    it "addestramento di un dataset non visibile → 404 (anti-BOLA)" do
      altrove = create(:dataset_training, :done)

      get "/cli/v1/datasets/#{altrove.dataset_id}/trainings/#{altrove.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "addestramento di un ALTRO dataset visibile → 404 (l'id non si prende in prestito)" do
      altro = create(:dataset_training, :done, dataset: create(:dataset, project:))

      get "/cli/v1/datasets/#{dataset.id}/trainings/#{altro.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET index" do
    it "elenca gli addestramenti del dataset, dal più recente" do
      vecchio = create(:dataset_training, :done, dataset:, created_at: 2.days.ago)
      nuovo = create(:dataset_training, dataset:, status: :running, created_at: 1.hour.ago)
      create(:dataset_training, :done)

      get "/cli/v1/datasets/#{dataset.id}/trainings", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |t| t["id"] }).to eq([ nuovo.id, vecchio.id ])
      expect(response.parsed_body["meta"]).to include("total" => 2)
    end

    it "membro assegnato senza datasets.train → 200" do
      create(:dataset_training, :done, dataset:)

      get "/cli/v1/datasets/#{dataset.id}/trainings", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].length).to eq(1)
    end
  end
end
