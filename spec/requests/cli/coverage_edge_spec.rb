# frozen_string_literal: true

require "rails_helper"

# Copertura dei rami edge del codice /cli (auth header, device-flow, approvazione) che gli spec
# happy-path non esercitano. Tiene la branch coverage del dominio CLI completa.
RSpec.describe "Cli — rami edge", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  describe "UserTokenAuthentication" do
    it "header Authorization non-Bearer → 401" do
      get "/cli/v1/whoami", headers: { "Authorization" => "Basic Zm9vOmJhcg==" }
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("R401-CLIAUTH-001")
    end

    it "Bearer con token vuoto → 401" do
      get "/cli/v1/whoami", headers: { "Authorization" => "Bearer " }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "Cli::Authorizations — rami senza grant" do
    def sign_in_as(acc)
      post login_path, params: { email: acc.email, password: "Secret123!" }
    end

    it "show senza user_code → 404" do
      sign_in_as(account)
      get cli_authorize_path
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include('data-test="cli-authorize-unknown"')
    end

    it "approve con user_code sconosciuto → 404" do
      sign_in_as(account)
      post cli_authorize_approve_path(user_code: "ZZZZ-ZZZZ"), params: { organization_id: organization.id }
      expect(response).to have_http_status(:not_found)
    end

    it "deny con user_code sconosciuto → schermata denied (no-op)" do
      sign_in_as(account)
      post cli_authorize_deny_path(user_code: "ZZZZ-ZZZZ")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="cli-authorize-denied"')
    end
  end

  describe "Accounts::Devices::Poll — rami edge" do
    it "grant approvato SENZA client_name → token coniato col nome di fallback 'CLI'" do
      post "/cli/device/authorize" # nessun client_name → grant.client_name nil
      data = response.parsed_body["data"]
      grant = Accounts::DeviceGrant.find_by!(user_code: data["user_code"])
      Accounts::Devices::Approve.call(grant:, account:, organization:)

      post "/cli/device/token", params: { device_code: data["device_code"] }
      expect(response).to have_http_status(:created)
      issued = Accounts::ApiToken.find_by!(
        token_digest: Digest::SHA256.hexdigest(response.parsed_body["data"]["access_token"])
      )
      expect(issued.name).to eq("CLI")
    end

    it "poll di un grant già in stato expired → expired_token (niente doppio expired!)" do
      code = "raw-already-expired"
      create(:device_grant, status: :expired, expires_at: 1.minute.ago,
                            device_code_digest: Digest::SHA256.hexdigest(code))

      post "/cli/device/token", params: { device_code: code }
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]["details"]["oauth_error"]).to eq("expired_token")
    end
  end
end
