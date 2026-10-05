# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Whoami", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401 R401-CLIAUTH-001" do
    get "/cli/v1/whoami"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]["code"]).to eq("R401-CLIAUTH-001")
  end

  it "bearer valido → 200 con account, org e lista permessi" do
    get "/cli/v1/whoami", headers: headers

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data["account"]["id"]).to eq(account.id)
    expect(data["account"]["email"]).to eq(account.email)
    expect(data["organization"]["id"]).to eq(organization.id)
    expect(data["token"]["prefix"]).to start_with("cyi_u_")
    expect(data["permissions"]).to be_an(Array)
  end

  # CYRA-717 — la riga di comando deve poter dire quanto manca senza fare conti sulla data.
  describe "scadenza del token" do
    it "riporta scadenza, giorni residui e stato" do
      get "/cli/v1/whoami", headers: headers

      token = response.parsed_body["data"]["token"]
      expect(Time.zone.parse(token["expires_at"]))
        .to be_within(1.minute).of(Accounts::ApiTokens::Issue::DEFAULT_LIFETIME.from_now)
      expect(token["expires_in_days"]).to eq(Accounts::Constants::API_TOKEN_DEFAULT_LIFETIME_DAYS)
      expect(token["expiry_status"]).to eq("ok")
    end

    it "stato due_soon quando manca meno della finestra di preavviso" do
      token = Accounts::ApiToken.find_by!(token_digest: Digest::SHA256.hexdigest(secret))
      token.update_column(:expires_at, 3.days.from_now)

      get "/cli/v1/whoami", headers: headers

      expect(response.parsed_body["data"]["token"]["expiry_status"]).to eq("due_soon")
      expect(response.parsed_body["data"]["token"]["expires_in_days"]).to eq(3)
    end

    it "un token di servizio senza scadenza riporta expires_at nullo e stato none" do
      service = create(:account, :service)
      create(:membership, account: service, organization:)
      service_secret = Accounts::ApiTokens::Issue
                       .call(account: service, organization:, name: "ci-deploy", expires_at: nil).value[:secret]

      get "/cli/v1/whoami", headers: { "Authorization" => "Bearer #{service_secret}" }

      token = response.parsed_body["data"]["token"]
      expect(token["expires_at"]).to be_nil
      expect(token["expires_in_days"]).to be_nil
      expect(token["expiry_status"]).to eq("none")
    end
  end

  # CYRA-717 — scaduto e mancante non sono la stessa cosa: chi ha un token scaduto deve leggere che
  # deve rifare l'accesso, non "token mancante o non valido" (che manda a cercare un errore di copia).
  it "token scaduto → 401 R401-CLIAUTH-002 con l'invito a rifare l'accesso" do
    token = Accounts::ApiToken.find_by!(token_digest: Digest::SHA256.hexdigest(secret))
    token.update_column(:expires_at, 1.hour.ago)

    get "/cli/v1/whoami", headers: headers

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]["code"]).to eq("R401-CLIAUTH-002")
    expect(response.parsed_body["error"]["message"]).to include("scaduto")
    expect(response.parsed_body["error"]["details"]["expired_at"]).to be_present
  end

  # La revoca è una decisione di qualcuno; la scadenza è il calendario. Se sono vere entrambe, vince
  # la prima: "scaduto, rifai l'accesso" nasconderebbe il fatto che quel token è stato chiuso.
  it "token revocato E scaduto → 401 R401-CLIAUTH-001, la revoca ha la precedenza" do
    token = Accounts::ApiToken.find_by!(token_digest: Digest::SHA256.hexdigest(secret))
    token.update_columns(revoked_at: 2.days.ago, expires_at: 1.hour.ago)

    get "/cli/v1/whoami", headers: headers

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]["code"]).to eq("R401-CLIAUTH-001")
  end

  it "token revocato → 401 R401-CLIAUTH-001 (non è una scadenza)" do
    token = Accounts::ApiToken.find_by!(token_digest: Digest::SHA256.hexdigest(secret))
    Accounts::ApiTokens::Revoke.call(token:)

    get "/cli/v1/whoami", headers: headers
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]["code"]).to eq("R401-CLIAUTH-001")
  end

  it "account god → vede tutti i permessi del catalogo" do
    god = create(:account, god: true)
    create(:membership, account: god, organization:)
    god_secret = Accounts::ApiTokens::Issue.call(account: god, organization:, name: "CLI").value[:secret]

    get "/cli/v1/whoami", headers: { "Authorization" => "Bearer #{god_secret}" }

    expect(response.parsed_body["data"]["permissions"]).to match_array(Authorization::Catalog.keys)
  end
end
