# frozen_string_literal: true

require "rails_helper"

# CYRA-77 — leggere UN secret dal terminale lasciava nel registro la stessa riga di un download
# completo: «ha letto l'ambiente», senza dire quale valore. Il conteggio non è una traccia d'accesso.
# Questo endpoint serve il singolo valore e registra il NOME, col canale da cui è arrivata la richiesta.
RSpec.describe "Cli::V1::Projects::Secrets#value (CYRA-77)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }
  let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  def seed_secret(name:, value: "v")
    Secrets::Variables::Set.call(project:, environment:, name:, value:).value
  end

  context "owner (secrets.manage → implica read)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "per NOME → 200 col solo valore richiesto" do
      seed_secret(name: "API_KEY", value: "s3cr3t")
      seed_secret(name: "OTHER", value: "altro")

      get "/cli/v1/projects/#{project.id}/secrets/API_KEY/value",
          params: { environment: "production" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq({ "name" => "API_KEY", "value" => "s3cr3t" })
      expect(response.body).not_to include("altro")
    end

    it "registra la lettura col NOME del secret e il canale cli" do
      seed_secret(name: "API_KEY", value: "s3cr3t")

      expect do
        get "/cli/v1/projects/#{project.id}/secrets/API_KEY/value",
            params: { environment: "production" }, headers: headers
      end.to change { project.secret_events.where(action: "read", name: "API_KEY", channel: "cli").count }.by(1)
    end

    it "il nome minuscolo è lo stesso secret (i nomi sono UPPER_SNAKE)" do
      seed_secret(name: "API_KEY", value: "s3cr3t")

      get "/cli/v1/projects/#{project.id}/secrets/api_key/value",
          params: { environment: "production" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["value"]).to eq("s3cr3t")
    end

    it "per UUID → 200, l'ambiente lo dice il secret stesso" do
      variable = seed_secret(name: "API_KEY", value: "s3cr3t")

      get "/cli/v1/projects/#{project.id}/secrets/#{variable.id}/value", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["value"]).to eq("s3cr3t")
    end

    it "nome inesistente → 404 (nessun valore, nessuna lettura registrata)" do
      environment

      expect do
        get "/cli/v1/projects/#{project.id}/secrets/MANCANTE/value",
            params: { environment: "production" }, headers: headers
      end.not_to change { project.secret_events.where(action: "read").count }

      expect(response).to have_http_status(:not_found)
    end

    it "nome senza environment → R422 (input invalido), distinguibile dal secret inesistente" do
      seed_secret(name: "API_KEY", value: "s3cr3t")

      get "/cli/v1/projects/#{project.id}/secrets/API_KEY/value", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SECRET-001")
    end

    # Il valore che `cyi secrets get` restituiva filtrando il bundle comprendeva anche i nomi
    # delegati dallo shared: l'endpoint per-nome non può perderli, o la lettura mirata darebbe 404
    # su un secret che il download completo consegna.
    it "un nome DELEGATO dallo shared è leggibile come gli altri" do
      shared_value = Secrets::Shared::Save.call(organization:, environment:, name: "shared_key",
                                                value: "shared-plain").value
      Secrets::Shared::Delegate.call(shared_value:, project:)

      get "/cli/v1/projects/#{project.id}/secrets/SHARED_KEY/value",
          params: { environment: "production" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["value"]).to eq("shared-plain")
    end

    # CYRA-79 — `cyi run` applica gli scostamenti personali; la lettura mirata deve dare lo STESSO
    # valore, altrimenti il terminale mostrerebbe un default che quella persona non usa mai.
    it "lo scostamento personale vince sul default, come nel download completo" do
      seed_secret(name: "API_KEY", value: "default")
      Secrets::Overrides::Set.call(project:, environment:, account:, name: "API_KEY",
                                   value: "personale", actor: account)

      get "/cli/v1/projects/#{project.id}/secrets/API_KEY/value",
          params: { environment: "production" }, headers: headers

      expect(response.parsed_body["data"]["value"]).to eq("personale")
    end
  end

  context "attore senza secrets.read" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end

    it "→ 403, nessun valore" do
      seed_secret(name: "API_KEY", value: "s3cr3t")

      get "/cli/v1/projects/#{project.id}/secrets/API_KEY/value",
          params: { environment: "production" }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("s3cr3t")
    end
  end

  # CYRA-78 — il confine ambienti vale anche sulla lettura mirata, e il tentativo lascia traccia.
  context "attore ristretto a staging" do
    let(:staging) { create(:environment, organization:, code: "staging").tap { |e| project.environments << e } }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
      # CYRA-721 — qui si prova il CONFINE, non il permesso: l'attore può leggere (secrets.read), e il
      # 403 deve arrivare dall'ambiente vietato.
      create(:account_permission, account:, organization:, permission_key: "secrets.read", effect: :allow)
      staging
      organization.memberships.find_by!(account:).update!(secret_environment_codes: [ "staging" ])
    end

    it "ambiente vietato → 403 e un tentativo registrato col canale cli" do
      seed_secret(name: "API_KEY", value: "s3cr3t")

      expect do
        get "/cli/v1/projects/#{project.id}/secrets/API_KEY/value",
            params: { environment: "production" }, headers: headers
      end.to change { project.secret_events.where(action: "denied", channel: "cli").count }.by(1)

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("s3cr3t")
    end

    it "il secret indicato per UUID su un ambiente vietato → 403, il valore non esce" do
      variable = seed_secret(name: "API_KEY", value: "s3cr3t")

      expect do
        get "/cli/v1/projects/#{project.id}/secrets/#{variable.id}/value", headers: headers
      end.to change { project.secret_events.where(action: "denied", name: "API_KEY", channel: "cli").count }.by(1)

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("s3cr3t")
    end
  end
end
