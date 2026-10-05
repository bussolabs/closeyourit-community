# frozen_string_literal: true

require "rails_helper"

# Prova END-TO-END del confine di accesso di un service account: il suo token cyi_u_ (account-proxy)
# legge/scrive i secret SOLO dei progetti concessi (via visibilità + override allow secrets.read/manage),
# ed è negato su tutto il resto. Nessuna authz nuova: riusa Cli::V1::Projects::SecretsController + RBAC.
RSpec.describe "Cli::V1 accesso secret dei service account", type: :request do
  let(:organization) { create(:organization, slug: "acme") }
  let(:granted)   { create(:project, organization: organization) }
  let(:ungranted) { create(:project, organization: organization) }
  let(:environment) do
    create(:environment, organization: organization, code: "production").tap { |e| granted.environments << e }
  end

  def token_for(account)
    Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "CLI").value[:secret]
  end

  context "service account con progetto concesso + secrets read/write" do
    let(:account) do
      Accounts::Service::Create.call(
        organization: organization, name: "Deploy Bot", project_ids: [ granted.id ], grant_secrets: true
      ).value
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "scrive un secret sul progetto concesso → 201 e lo cifra" do
      environment
      post "/cli/v1/projects/#{granted.id}/secrets", headers: headers,
                                                     params: { confirm: "1", environment: "production", name: "API_KEY", value: "s3cr3t" }

      expect(response).to have_http_status(:created)
      expect(granted.secret_variables.find_by(name: "API_KEY").value).to eq("s3cr3t")
    end

    it "legge il bundle decifrato del progetto concesso → 200" do
      Secrets::Variables::Set.call(project: granted, environment: environment, name: "A", value: "1").value
      get "/cli/v1/projects/#{granted.id}/secrets/bundle", params: { environment: "production" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq({ "A" => "1" })
    end

    it "l'audit registra il service account come actor della lettura" do
      Secrets::Variables::Set.call(project: granted, environment: environment, name: "A", value: "1").value
      get "/cli/v1/projects/#{granted.id}/secrets/bundle", params: { environment: "production" }, headers: headers

      expect(granted.secret_events.find_by(action: "read").actor).to eq(account)
    end

    it "sul progetto NON concesso: index → 404 (anti-BOLA, invisibile)" do
      get "/cli/v1/projects/#{ungranted.id}/secrets", params: { environment: "production" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "sul progetto NON concesso: create → 404 (non lo vede nemmeno)" do
      post "/cli/v1/projects/#{ungranted.id}/secrets", headers: headers,
                                                       params: { environment: "production", name: "X", value: "v" }
      expect(response).to have_http_status(:not_found)
    end
  end

  context "service account visibile ma SENZA grant_secrets" do
    let(:account) do
      Accounts::Service::Create.call(
        organization: organization, name: "Reader Bot", project_ids: [ granted.id ]
      ).value
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "bundle → 403 (vede il progetto ma non ha secrets.read)" do
      environment
      get "/cli/v1/projects/#{granted.id}/secrets/bundle", params: { environment: "production" }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  # Fase 2 — restrizione per environment: il service account può toccare i secret SOLO degli env
  # consentiti (allow-list sulla membership); production negata anche con secrets.manage sul progetto.
  context "service account ristretto a staging (niente production)" do
    let(:staging)    { create(:environment, organization: organization, code: "staging").tap { |e| granted.environments << e } }
    let(:production) { create(:environment, organization: organization, code: "production").tap { |e| granted.environments << e } }
    let(:account) do
      Accounts::Service::Create.call(
        organization: organization, name: "Staging Bot", project_ids: [ granted.id ],
        grant_secrets: true, secret_environment_codes: [ "staging" ]
      ).value
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    before { staging && production }

    it "legge il bundle di staging → 200" do
      Secrets::Variables::Set.call(project: granted, environment: staging, name: "A", value: "1").value
      get "/cli/v1/projects/#{granted.id}/secrets/bundle", params: { environment: "staging" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq({ "A" => "1" })
    end

    it "sul bundle di production → 403 R403-SECRET-001 (non nei secret nemmeno con secrets.manage)" do
      get "/cli/v1/projects/#{granted.id}/secrets/bundle", params: { environment: "production" }, headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-SECRET-001")
    end

    it "scrive su staging → 201, su production → 403" do
      post "/cli/v1/projects/#{granted.id}/secrets", headers: headers, params: { confirm: "1", environment: "staging", name: "K", value: "v" }
      expect(response).to have_http_status(:created)

      post "/cli/v1/projects/#{granted.id}/secrets", headers: headers, params: { confirm: "1", environment: "production", name: "K", value: "v" }
      expect(response).to have_http_status(:forbidden)
    end

    it "index senza environment elenca solo i secret degli env consentiti (niente production)" do
      Secrets::Variables::Set.call(project: granted, environment: staging, name: "STG", value: "1").value
      Secrets::Variables::Set.call(project: granted, environment: production, name: "PRD", value: "2").value
      get "/cli/v1/projects/#{granted.id}/secrets", headers: headers
      names = response.parsed_body["data"].map { |r| r["name"] }
      expect(names).to include("STG")
      expect(names).not_to include("PRD")
    end

    # CYRA-235 — il confine environment era saltato quando il secret si indica con l'UUID (ramo per id
    # di find_variable!): un SA ristretto a staging poteva cancellare un secret di production. Il rifiuto
    # deve essere identico a quello per nome fuori ambiente (R403-SECRET-001) e il secret restare.
    it "cancella per UUID un secret di production → 403 R403-SECRET-001 e il secret resta" do
      prd = Secrets::Variables::Set.call(project: granted, environment: production, name: "PRD", value: "2").value
      delete "/cli/v1/projects/#{granted.id}/secrets/#{prd.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-SECRET-001")
      expect(granted.secret_variables.exists?(prd.id)).to be(true)
    end

    it "cancella per UUID un secret di staging (env consentito) → 204 e sparisce" do
      stg = Secrets::Variables::Set.call(project: granted, environment: staging, name: "STG", value: "1").value
      delete "/cli/v1/projects/#{granted.id}/secrets/#{stg.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(granted.secret_variables.exists?(stg.id)).to be(false)
    end

    # CYRA-234 — la sync GitHub spinge TUTTI gli slot mappati del repo (production/staging/preview),
    # non è filtrabile per environment: un SA ristretto a staging che l'attivasse/lanciasse leggerebbe
    # e pubblicherebbe anche production, aggirando il confine. Con restrizioni → sempre negato.
    context "confine sulla sync verso GitHub (CYRA-234)" do
      let!(:repository) do
        create(:github_repository, project: granted, sync_secrets: false,
                                   installation: create(:github_installation, organization: organization))
      end

      # github.manage AGGIUNTIVO al grant_secrets del SA (override additivo: SetAccountPermissions farebbe
      # un reconcile completo, cancellando i permessi secret). Così il SA ha secrets.read + github.manage.
      before do
        account.account_permissions.create!(organization: organization, permission_key: "github.manage", effect: "allow")
      end

      it "accendere sync_secrets → 403 e il flag NON cambia" do
        patch "/cli/v1/projects/#{granted.id}/github", headers: headers, params: { sync_secrets: true }

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body["error"]["code"]).to eq("R403-SECRET-001")
        expect(repository.reload.sync_secrets).to be(false)
      end

      it "lanciare la sync → 403 R403-SECRET-001 e nessun job accodato" do
        expect { post "/cli/v1/projects/#{granted.id}/secrets/sync", headers: headers }
          .not_to have_enqueued_job(Secrets::Github::SyncJob)

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body["error"]["code"]).to eq("R403-SECRET-001")
      end

      it "gli altri flag di binding restano gestibili (non toccano i valori) → 200" do
        patch "/cli/v1/projects/#{granted.id}/github", headers: headers, params: { tag_binding_enabled: false }

        expect(response).to have_http_status(:ok)
        expect(repository.reload.tag_binding_enabled).to be(false)
      end
    end
  end
end
