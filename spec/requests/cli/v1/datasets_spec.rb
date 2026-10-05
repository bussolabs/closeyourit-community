# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Datasets", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization:, key: "ACME") }

  before { create(:membership, account: owner, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account: owner, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro assegnato al progetto ma SENZA datasets.manage: legge, non scrive.
  def reader_headers
    reader = create(:account)
    create(:membership, account: reader, organization:, role: :member)
    create(:project_membership, account: reader, project:)
    reader_secret = Accounts::ApiTokens::Issue.call(account: reader, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{reader_secret}" }
  end

  # Schema minimo valido: un input e un target (la regola del canale web, ≥1 e ≥1).
  def schema
    [ { label: "Foto", kind: "photo", role: "input" },
      { label: "Esito", kind: "category", role: "target", options: "ok,ko" } ]
  end

  it "senza token → 401" do
    get "/cli/v1/datasets"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "elenca i dataset visibili con schema, conteggio righe e progetto" do
      dataset = create(:dataset, project:, name: "Cartelli", created_by: owner)
      create(:dataset_column, dataset:, code: "foto", label: "Foto", kind: :photo, role: :input)
      create(:dataset_row, dataset:)

      get "/cli/v1/datasets", headers: headers

      expect(response).to have_http_status(:ok)
      riga = response.parsed_body["data"].sole
      expect(riga).to include("id" => dataset.id, "name" => "Cartelli", "status" => "draft",
                              "project" => "ACME", "project_id" => project.id, "rows_count" => 1)
      expect(riga["columns"].sole).to include("code" => "foto", "kind" => "photo", "role" => "input")
    end

    it "member assegnato senza datasets.manage → 200 (lettura = visibilità del progetto)" do
      create(:dataset, project:)

      get "/cli/v1/datasets", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].length).to eq(1)
    end

    it "non elenca i dataset di progetti non visibili (anti-BOLA)" do
      create(:dataset, project: create(:project, organization: create(:organization)))

      get "/cli/v1/datasets", headers: headers

      expect(response.parsed_body["data"]).to be_empty
    end

    it "?project= filtra per key del progetto, come il filtro del sito" do
      create(:dataset, project:, name: "Cartelli")
      create(:dataset, project: create(:project, organization:, key: "BETA"), name: "Altro")

      get "/cli/v1/datasets", params: { project: "acme" }, headers: headers

      expect(response.parsed_body["data"].pluck("name")).to eq([ "Cartelli" ])
    end

    it "?project= con un progetto non visibile → 404 (anti-BOLA)" do
      estraneo = create(:project, organization: create(:organization))

      get "/cli/v1/datasets", params: { project: estraneo.id }, headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "?q= cerca sul nome e ?status= filtra per stato, come il sito" do
      create(:dataset, project:, name: "Cartelli stradali")
      create(:dataset, project:, name: "Ricevute", status: :trained)

      get "/cli/v1/datasets", params: { q: "cartelli" }, headers: headers
      expect(response.parsed_body["data"].pluck("name")).to eq([ "Cartelli stradali" ])

      get "/cli/v1/datasets", params: { status: "trained" }, headers: headers
      expect(response.parsed_body["data"].pluck("name")).to eq([ "Ricevute" ])
    end
  end

  describe "GET show" do
    it "ritorna il dataset con le sue colonne ordinate" do
      dataset = create(:dataset, project:, name: "Cartelli", description: "Foto → esito", created_by: owner)
      create(:dataset_column, :target, dataset:, code: "esito", label: "Esito", position: 1)
      create(:dataset_column, dataset:, code: "foto", label: "Foto", kind: :photo, position: 0)

      get "/cli/v1/datasets/#{dataset.id}", headers: headers

      expect(response).to have_http_status(:ok)
      scheda = response.parsed_body["data"]
      expect(scheda).to include("name" => "Cartelli", "description" => "Foto → esito", "author" => owner.name)
      expect(scheda["columns"].pluck("code")).to eq(%w[foto esito])
    end

    it "dataset di un progetto non visibile → 404 (anti-BOLA)" do
      altrove = create(:dataset, project: create(:project, organization: create(:organization)))

      get "/cli/v1/datasets/#{altrove.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    it "crea il dataset con lo schema di colonne e lo registra in cronologia" do
      expect do
        post "/cli/v1/datasets",
             params: { project: "ACME", name: "Cartelli", description: "Foto → esito", columns: schema },
             headers: headers, as: :json
      end.to change(Datasets::Dataset, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("name" => "Cartelli", "project" => "ACME")
      dataset = Datasets::Dataset.sole
      expect(dataset.created_by).to eq(owner)
      expect(dataset.columns.ordered.map { |column| [ column.code, column.kind, column.role, column.options ] })
        .to eq([ [ "foto", "photo", "input", [] ], [ "esito", "category", "target", %w[ok ko] ] ])
      expect(dataset.activity_events.pluck(:action)).to eq([ "created" ])
    end

    it "accetta anche l'UUID del progetto (e `project_id`, come il sito)" do
      post "/cli/v1/datasets",
           params: { project_id: project.id, name: "Cartelli", columns: schema },
           headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(Datasets::Dataset.sole.project).to eq(project)
    end

    it "senza datasets.manage → 403 e nessun dataset creato" do
      expect do
        post "/cli/v1/datasets", params: { project: "ACME", name: "Cartelli", columns: schema },
                                 headers: reader_headers, as: :json
      end.not_to change(Datasets::Dataset, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-CLIAUTH-002")
    end

    it "progetto non visibile → 404 (anti-BOLA, mai 403)" do
      estraneo = create(:project, organization: create(:organization))

      post "/cli/v1/datasets", params: { project: estraneo.id, name: "Cartelli", columns: schema },
                               headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "senza colonna target → 422 R422-DATASET-001 col motivo, come sul sito" do
      post "/cli/v1/datasets",
           params: { project: "ACME", name: "Cartelli", columns: [ { label: "Foto", kind: "photo", role: "input" } ] },
           headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("code" => "R422-DATASET-001",
                                                       "message" => I18n.t("datasets.errors.no_target"))
    end

    it "nome vuoto → 422 con i campi in errore" do
      post "/cli/v1/datasets", params: { project: "ACME", name: "", columns: schema }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "details")).to include("name")
    end
  end

  describe "PATCH update" do
    let(:dataset) { create(:dataset, project:, name: "Cartelli", description: "Vecchia") }

    before do
      create(:dataset_column, dataset:, code: "foto", label: "Foto", kind: :photo, position: 0)
      create(:dataset_column, :target, dataset:, code: "esito", label: "Esito", position: 1)
    end

    # La differenza fra "campo assente" (non toccarlo) e "campo vuoto" (svuotalo) è tutta la
    # semantica di una PATCH: rinominare un dataset non deve portarsi via il suo schema.
    it "modifica solo i campi presenti e lascia intatte le colonne" do
      patch "/cli/v1/datasets/#{dataset.id}", params: { name: "Cartelli 2026" }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(dataset.reload.name).to eq("Cartelli 2026")
      expect(dataset.description).to eq("Vecchia")
      expect(dataset.columns.ordered.pluck(:code)).to eq(%w[foto esito])
    end

    it "sostituisce lo schema se le colonne sono presenti e il dataset non ha righe" do
      patch "/cli/v1/datasets/#{dataset.id}",
            params: { columns: [ { label: "Immagine", kind: "photo", role: "input" },
                                 { label: "Voto", kind: "number", role: "target" } ] },
            headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(dataset.reload.columns.ordered.pluck(:code)).to eq(%w[immagine voto])
    end

    it "dataset con righe: le colonne restano quelle, come sul sito" do
      create(:dataset_row, dataset:)

      patch "/cli/v1/datasets/#{dataset.id}",
            params: { name: "Cartelli 2026", columns: [ { label: "Solo io", kind: "text", role: "input" } ] },
            headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(dataset.reload.name).to eq("Cartelli 2026")
      expect(dataset.columns.ordered.pluck(:code)).to eq(%w[foto esito])
    end

    it "senza datasets.manage → 403" do
      patch "/cli/v1/datasets/#{dataset.id}", params: { name: "Mio" }, headers: reader_headers, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(dataset.reload.name).to eq("Cartelli")
    end
  end

  describe "DELETE destroy" do
    it "elimina il dataset" do
      dataset = create(:dataset, project:)

      expect { delete "/cli/v1/datasets/#{dataset.id}", headers: headers }
        .to change(Datasets::Dataset, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "senza datasets.manage → 403" do
      dataset = create(:dataset, project:)

      expect { delete "/cli/v1/datasets/#{dataset.id}", headers: reader_headers }
        .not_to change(Datasets::Dataset, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  # Scenario 1 del ticket: quello che si fa da terminale è identico a quello che si fa dal sito —
  # non "equivalente", proprio lo stesso dato, che compare nella stessa pagina.
  describe "parità col canale web" do
    it "il dataset creato da terminale compare sul sito con lo stesso schema" do
      post "/cli/v1/datasets", params: { project: "ACME", name: "Cartelli", columns: schema },
                               headers: headers, as: :json
      dataset = Datasets::Dataset.sole

      post login_path, params: { email: owner.email, password: "Secret123!" }
      get member_dataset_path(dataset)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Cartelli")
      expect(response.body).to include("Esito")
    end
  end
end
