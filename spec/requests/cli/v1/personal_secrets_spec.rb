# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::PersonalSecrets", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def owned
    Secrets::Personal::Variable.for(account:, organization:)
  end

  describe "autenticazione" do
    it "senza bearer → 401 R401-CLIAUTH-001" do
      get "/cli/v1/personal_secrets"
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("R401-CLIAUTH-001")
    end
  end

  describe "GET /cli/v1/personal_secrets" do
    it "ritorna solo i miei secret e NON espone il valore" do
      mine = create(:personal_secret_variable, account:, organization:, name: "MY_KEY", value: "s3cr3t")
      other = create(:account)
      create(:membership, account: other, organization:)
      create(:personal_secret_variable, account: other, organization:, name: "OTHER_KEY")

      get "/cli/v1/personal_secrets", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.map { |v| v["id"] }).to contain_exactly(mine.id)
      expect(data.first).not_to have_key("value")
      expect(response.body).not_to include("s3cr3t")
    end
  end

  describe "POST /cli/v1/personal_secrets" do
    it "crea (upsert) → 201, senza esporre il valore" do
      post "/cli/v1/personal_secrets", params: { name: "api_key", value: "v1" }, headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["name"]).to eq("API_KEY")
      expect(response.parsed_body["data"]).not_to have_key("value")
      expect(owned.find_by(name: "API_KEY").value).to eq("v1")
    end

    it "nome invalido → 422 R422-PERSONALSECRET-001" do
      post "/cli/v1/personal_secrets", params: { name: "1BAD", value: "x" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PERSONALSECRET-001")
    end
  end

  describe "GET /cli/v1/personal_secrets/bundle" do
    it "ritorna la mappa decifrata e registra un evento read" do
      create(:personal_secret_variable, account:, organization:, name: "A_KEY", value: "a")
      create(:personal_secret_variable, account:, organization:, name: "B_KEY", value: "b")

      expect { get "/cli/v1/personal_secrets/bundle", headers: headers }
        .to change { Secrets::Personal::Event.for(account:, organization:).where(action: "read").count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq({ "A_KEY" => "a", "B_KEY" => "b" })
    end

    it "bundle vuoto → { data: {} }" do
      get "/cli/v1/personal_secrets/bundle", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq({})
    end
  end

  describe "POST /cli/v1/personal_secrets/import" do
    it "importa in bulk → 201 con conteggio" do
      params = { variables: [ { name: "A", value: "1" }, { name: "B", value: "2" } ] }

      # upsert per-voce intenzionale su una lista bounded (import), non un N+1 lazy-load di produzione.
      expect { allow_n_plus_one { post "/cli/v1/personal_secrets/import", params:, headers: headers } }
        .to change { owned.count }.by(2)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["imported"]).to eq(2)
    end

    it "una voce invalida → 422 e nessuna scrittura (all-or-nothing)" do
      params = { variables: [ { name: "GOOD", value: "1" }, { name: "1BAD", value: "2" } ] }

      allow_n_plus_one { post "/cli/v1/personal_secrets/import", params:, headers: headers }

      expect(response).to have_http_status(:unprocessable_content)
      expect(owned.count).to eq(0)
    end
  end

  describe "DELETE /cli/v1/personal_secrets/:id" do
    it "elimina per UUID → 204" do
      s = create(:personal_secret_variable, account:, organization:)
      delete "/cli/v1/personal_secrets/#{s.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Secrets::Personal::Variable.exists?(s.id)).to be(false)
    end

    it "elimina per NAME → 204" do
      create(:personal_secret_variable, account:, organization:, name: "API_KEY")
      delete "/cli/v1/personal_secrets/api_key", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(owned.where(name: "API_KEY")).not_to exist
    end

    it "secret di un altro account → 404 (anti-BOLA)" do
      other = create(:account)
      create(:membership, account: other, organization:)
      foreign = create(:personal_secret_variable, account: other, organization:)

      delete "/cli/v1/personal_secrets/#{foreign.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(Secrets::Personal::Variable.exists?(foreign.id)).to be(true)
    end
  end
end
