# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::SharedSecrets", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:environment) { create(:environment, organization:, code: "production") }

  before { create(:membership, account: owner, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account: owner, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  describe "autenticazione" do
    it "senza bearer → 401 R401-CLIAUTH-001" do
      get "/cli/v1/shared_secrets"
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("R401-CLIAUTH-001")
    end
  end

  describe "permessi" do
    it "membro senza shared_secrets.manage → 403 R403-CLIAUTH-002" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      get "/cli/v1/shared_secrets", headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  describe "GET /cli/v1/shared_secrets" do
    it "owner (shared_secrets.manage) → 200 con i metadati, MAI il valore" do
      value = Secrets::Shared::Save.call(organization:, environment:, name: "API_KEY", value: "s3cr3t",
                                          actor: owner, skip_confirmation: true).value

      get "/cli/v1/shared_secrets", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      row = data.first
      expect(row["id"]).to eq(value.shared_variable.id)
      expect(row["name"]).to eq("API_KEY")
      expect(row).not_to have_key("value")
      expect(response.body).not_to include("s3cr3t")
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "esclude le variabili di un'altra org (anti-BOLA)" do
      Secrets::Shared::Save.call(organization:, environment:, name: "MINE", value: "a",
                                  actor: owner, skip_confirmation: true)
      foreign_org = create(:organization)
      foreign_env = create(:environment, organization: foreign_org)
      Secrets::Shared::Save.call(organization: foreign_org, environment: foreign_env, name: "OTHER",
                                  value: "b", skip_confirmation: true)

      get "/cli/v1/shared_secrets", headers: headers

      names = response.parsed_body["data"].map { |v| v["name"] }
      expect(names).to contain_exactly("MINE")
    end

    it "membro con shared_secrets.manage concesso esplicitamente → 200" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      Authorization::SetAccountPermissions.call(organization:, account: member,
                                                allow_keys: [ "shared_secrets.manage" ], actor: owner)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      get "/cli/v1/shared_secrets", headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /cli/v1/shared_secrets" do
    it "crea (upsert) su un environment (per code) → 201, senza esporre il valore" do
      post "/cli/v1/shared_secrets", params: { confirm: "1", name: "api_key", environment: environment.code, value: "v1" },
                                     headers: headers

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["name"]).to eq("API_KEY")
      expect(data).not_to have_key("value")
      expect(response.body).not_to include("v1")
      variable = organization.shared_secret_variables.find_by(name: "API_KEY")
      expect(variable.values.find_by(environment:).value).to eq("v1")
    end

    it "accetta l'environment per UUID → 201" do
      post "/cli/v1/shared_secrets", params: { confirm: "1", name: "api_key", environment: environment.id, value: "v1" },
                                     headers: headers

      expect(response).to have_http_status(:created)
    end

    it "accetta una stringa vuota esplicita ma rifiuta value assente" do
      post "/cli/v1/shared_secrets", params: { confirm: "1", name: "optional", environment: environment.code, value: "" },
                                     headers: headers

      expect(response).to have_http_status(:created)
      expect(organization.shared_secret_variables.find_by!(name: "OPTIONAL").values.first.value).to eq("")

      post "/cli/v1/shared_secrets", params: { confirm: "1", name: "missing", environment: environment.code }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-SHARED-001")
    end

    it "due create con lo stesso nome → upsert, non duplica la variabile" do
      post "/cli/v1/shared_secrets", params: { confirm: "1", name: "api_key", environment: environment.code, value: "old" },
                                     headers: headers
      expect do
        post "/cli/v1/shared_secrets", params: { confirm: "1", name: "api_key", environment: environment.code, value: "new" },
                                       headers: headers
      end.not_to change { organization.shared_secret_variables.count }

      variable = organization.shared_secret_variables.find_by(name: "API_KEY")
      expect(variable.values.find_by(environment:).value).to eq("new")
    end

    it "nome invalido → 422 R422-SHARED-001" do
      post "/cli/v1/shared_secrets", params: { confirm: "1", name: "1BAD", environment: environment.code, value: "x" },
                                     headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SHARED-001")
    end

    it "environment inesistente → 422 R422-SHARED-001" do
      post "/cli/v1/shared_secrets", params: { confirm: "1", name: "API_KEY", environment: "nope", value: "x" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SHARED-001")
    end

    it "environment mancante → 422 R422-SHARED-001" do
      post "/cli/v1/shared_secrets", params: { confirm: "1", name: "API_KEY", value: "x" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SHARED-001")
    end

    it "environment di un'altra org → 422 (anti-BOLA, non referenziabile)" do
      foreign_environment = create(:environment) # altra org

      post "/cli/v1/shared_secrets", params: { confirm: "1", name: "API_KEY", environment: foreign_environment.id, value: "x" },
                                     headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SHARED-001")
      expect(Secrets::Shared::Variable.where(organization:)).to be_empty
    end

    it "aggiorna un valore già delegato senza il flusso di conferma del web (skip_confirmation)" do
      project = create(:project, organization:)
      create(:project_environment, project:, environment:)
      shared = Secrets::Shared::Save.call(organization:, environment:, name: "API_KEY", value: "one",
                                          actor: owner, skip_confirmation: true).value
      Secrets::Shared::Delegate.call(shared_value: shared, project:)

      post "/cli/v1/shared_secrets", params: { confirm: "1", name: "api_key", environment: environment.code, value: "two" },
                                     headers: headers

      expect(response).to have_http_status(:created)
      expect(shared.reload.value).to eq("two")
    end

    it "membro senza shared_secrets.manage → 403" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      post "/cli/v1/shared_secrets", params: { name: "API_KEY", environment: environment.code, value: "x" },
                                     headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  describe "DELETE /cli/v1/shared_secrets/:id" do
    def save_shared(name: "API_KEY", env: environment, value: "v1")
      Secrets::Shared::Save.call(organization:, environment: env, name:, value:, actor: owner,
                                 skip_confirmation: true).value
    end

    # NOTA: un solo environment di proposito. Con 2+ Value sulla stessa variabile,
    # Secrets::Shared::Delete/Impact ricalcolano l'impatto con un Impact.call per-value (ciascuno
    # interroga da sé `.projects.includes(...)`) → N query identiche per N ambienti: N+1 PRE-ESISTENTE
    # nel service condiviso (Member::SharedSecretsController#destroy non ha oggi copertura request-spec
    # che lo eserciti con 2+ ambienti, quindi Prosopite non l'aveva mai intercettato). Fuori scope per
    # questo canale CLI (fix toccherebbe Secrets::Shared::Impact/Delete condivisi col web) — segnalato
    # a parte, non silenziato con allow_n_plus_one (riservato a setup/idempotenza, non a N+1 di produzione).
    it "elimina la variabile e il suo valore per UUID → 204" do
      value = save_shared
      variable = value.shared_variable

      delete "/cli/v1/shared_secrets/#{variable.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Secrets::Shared::Variable.exists?(variable.id)).to be(false)
      expect(Secrets::Shared::Value.exists?(value.id)).to be(false)
    end

    it "elimina per NAME → 204" do
      save_shared(name: "API_KEY")

      delete "/cli/v1/shared_secrets/api_key", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(organization.shared_secret_variables.where(name: "API_KEY")).not_to exist
    end

    it "variabile di un'altra organizzazione → 404 (anti-BOLA)" do
      foreign_org = create(:organization)
      foreign_env = create(:environment, organization: foreign_org)
      foreign = Secrets::Shared::Save.call(organization: foreign_org, environment: foreign_env, name: "TOKEN",
                                           value: "x", skip_confirmation: true).value.shared_variable

      delete "/cli/v1/shared_secrets/#{foreign.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(Secrets::Shared::Variable.exists?(foreign.id)).to be(true)
    end

    it "elimina un valore delegato senza il banner di conferma del web (auto-confermato) → 204" do
      project = create(:project, organization:)
      create(:project_environment, project:, environment:)
      shared = save_shared
      Secrets::Shared::Delegate.call(shared_value: shared, project:)
      variable = shared.shared_variable

      delete "/cli/v1/shared_secrets/#{variable.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Secrets::Shared::Variable.exists?(variable.id)).to be(false)
    end

    it "Delete in errore (digest non combaciante) → render_error col codice/status del Result" do
      variable = save_shared.shared_variable
      allow(::Secrets::Shared::Delete).to receive(:call).and_return(
        Result.err(AppError.new("Conferma obsoleta", code: "R409-SHARED-001", details: []))
      )

      delete "/cli/v1/shared_secrets/#{variable.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R409-SHARED-001")
      expect(Secrets::Shared::Variable.exists?(variable.id)).to be(true)
    end

    it "membro senza shared_secrets.manage → 403" do
      variable = save_shared.shared_variable
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      delete "/cli/v1/shared_secrets/#{variable.id}", headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(Secrets::Shared::Variable.exists?(variable.id)).to be(true)
    end
  end
end
