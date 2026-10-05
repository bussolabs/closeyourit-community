# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Service::Accounts", type: :request do
  let(:organization) { create(:organization, slug: "acme") }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: organization, role: :owner) }

  def headers_for(account)
    secret = Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{secret}" }
  end

  let(:headers) { headers_for(owner) }

  describe "autorizzazione" do
    it "membro senza members.manage → 403" do
      member = create(:account)
      create(:membership, account: member, organization: organization, role: :member)
      get "/cli/v1/service/accounts", headers: headers_for(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET index" do
    it "elenca i service account con restrizione env e token attivi" do
      create(:environment, organization: organization, code: "staging")
      svc = Accounts::Service::Create.call(organization: organization, name: "Bot",
                                           secret_environment_codes: [ "staging" ]).value

      get "/cli/v1/service/accounts", headers: headers

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["data"].find { |r| r["id"] == svc.id }
      expect(row["handle"]).to eq(svc.handle)
      expect(row["secret_environment_codes"]).to eq([ "staging" ])
      expect(row).to have_key("active_tokens_count")
    end
  end

  describe "POST create" do
    it "crea un service account (201) con secrets read/write + restrizione env" do
      create(:environment, organization: organization, code: "staging")

      post "/cli/v1/service/accounts", headers: headers,
                                       params: { confirm: "1", name: "Deploy Bot", grant_secrets: "1", secret_environment_codes: [ "staging" ] }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["secret_environment_codes"]).to eq([ "staging" ])
      account = organization.accounts.service.find(response.parsed_body["data"]["id"])
      expect(account.account_permissions.where(permission_key: "secrets.manage", effect: "allow")).to exist
    end

    it "senza nome → errore envelope R422" do
      post "/cli/v1/service/accounts", headers: headers, params: { name: "" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to match(/^R422-/)
    end
  end

  describe "PATCH update (restrizione environment)" do
    it "aggiorna i code consentiti (solo quelli dell'org)" do
      create(:environment, organization: organization, code: "staging")
      account = Accounts::Service::Create.call(organization: organization, name: "Bot").value

      patch "/cli/v1/service/accounts/#{account.id}", headers: headers,
                                                      params: { confirm: "1", secret_environment_codes: [ "staging", "inesistente" ] }

      expect(response).to have_http_status(:ok)
      expect(organization.memberships.find_by(account: account).secret_environment_codes).to eq([ "staging" ])
    end
  end

  describe "DELETE destroy (retire audit-safe)" do
    it "rimuove dall'org ma preserva l'account (audit)" do
      account = Accounts::Service::Create.call(organization: organization, name: "Bot").value

      delete "/cli/v1/service/accounts/#{account.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(organization.accounts.service.exists?(account.id)).to be(false)
      expect(Accounts::Account.exists?(account.id)).to be(true)
    end

    it "account di un'altra org → 404 (anti-BOLA)" do
      foreign = Accounts::Service::Create.call(organization: create(:organization, slug: "beta"), name: "F").value
      delete "/cli/v1/service/accounts/#{foreign.id}", params: { confirm: "1" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "se il retire fallisce → errore envelope, NON 204" do
      account = Accounts::Service::Create.call(organization: organization, name: "Bot").value
      allow(Accounts::Service::Retire).to receive(:call)
        .and_return(Result.err(AppError.new("boom", code: "R422-SERVICEACCOUNT-002")))

      delete "/cli/v1/service/accounts/#{account.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SERVICEACCOUNT-002")
    end
  end

  describe "token (reveal-once)" do
    let(:account) { Accounts::Service::Create.call(organization: organization, name: "Bot").value }

    it "POST tokens → 201 col segreto cyi_u_ mostrato una volta" do
      post "/cli/v1/service/accounts/#{account.id}/tokens", headers: headers, params: { confirm: "1", name: "ci-deploy" }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["secret"]).to start_with("cyi_u_")
      expect(account.api_tokens.where(name: "ci-deploy")).to exist
    end

    # CYRA-717 — l'eccezione: un account di servizio non ha un browser per rifare l'accesso ogni 90
    # giorni, quindi il suo token nasce senza scadenza (e la risposta lo dice esplicitamente).
    it "il token di un account di servizio nasce SENZA scadenza" do
      post "/cli/v1/service/accounts/#{account.id}/tokens", headers: headers, params: { confirm: "1", name: "ci-deploy" }

      expect(response.parsed_body["data"]).to have_key("expires_at")
      expect(response.parsed_body["data"]["expires_at"]).to be_nil
      expect(account.api_tokens.find_by!(name: "ci-deploy").expires_at).to be_nil
    end

    it "DELETE token → 204 e revoca" do
      token = Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "old", expires_at: nil).value[:token]
      delete "/cli/v1/service/accounts/#{account.id}/tokens/#{token.id}", params: { confirm: "1" }, headers: headers
      expect(response).to have_http_status(:no_content)
      expect(token.reload).to be_revoked
    end
  end
end
