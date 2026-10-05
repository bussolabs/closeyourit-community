# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::Device (device-flow)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  def authorize!
    post "/cli/device/authorize", params: { client_name: "closeyourit-cli/1.0" }
    response.parsed_body["data"]
  end

  it "authorize → 201 con device_code, user_code, verification_uri, interval" do
    data = authorize!

    expect(response).to have_http_status(:created)
    expect(data["device_code"]).to be_present
    expect(data["user_code"]).to match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/)
    expect(data["verification_uri"]).to end_with("/cli/authorize")
    expect(data["verification_uri_complete"]).to include("user_code=#{data['user_code']}")
    expect(data["interval"]).to eq(Accounts::Constants::DEVICE_POLL_INTERVAL)
  end

  it "poll prima dell'approvazione → 400 authorization_pending" do
    data = authorize!
    post "/cli/device/token", params: { device_code: data["device_code"] }

    expect(response).to have_http_status(:bad_request)
    error = response.parsed_body["error"]
    expect(error["code"]).to eq("R400-CLIAUTH-002")
    expect(error["details"]["oauth_error"]).to eq("authorization_pending")
  end

  it "device_code sconosciuto → 401 invalid_grant" do
    post "/cli/device/token", params: { device_code: "inesistente" }

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]["code"]).to eq("R401-CLIAUTH-001")
  end

  it "flusso completo: authorize → approva → poll rilascia un token utilizzabile, una volta sola" do
    data = authorize!
    grant = Accounts::DeviceGrant.find_by!(user_code: data["user_code"])
    Accounts::Devices::Approve.call(grant:, account:, organization:)

    post "/cli/device/token", params: { device_code: data["device_code"] }
    expect(response).to have_http_status(:created)
    access_token = response.parsed_body["data"]["access_token"]
    expect(access_token).to start_with("cyi_u_")

    # Il token rilasciato funziona davvero sull'API dati.
    get "/cli/v1/whoami", headers: { "Authorization" => "Bearer #{access_token}" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]["account"]["id"]).to eq(account.id)

    # Single-use: un secondo poll immediato NON rilascia un nuovo token (errore 4xx).
    post "/cli/device/token", params: { device_code: data["device_code"] }
    expect(response.status).to be >= 400
  end

  # CYRA-717 — l'accesso da terminale dura 90 giorni: la risposta lo dice subito, così `login` può
  # stamparlo invece di lasciar credere che valga per sempre.
  it "il token rilasciato porta con sé la scadenza (data + secondi residui)" do
    data = authorize!
    grant = Accounts::DeviceGrant.find_by!(user_code: data["user_code"])
    Accounts::Devices::Approve.call(grant:, account:, organization:)

    post "/cli/device/token", params: { device_code: data["device_code"] }

    token = response.parsed_body["data"]["token"]
    expect(Time.zone.parse(token["expires_at"]))
      .to be_within(1.minute).of(Accounts::ApiTokens::Issue::DEFAULT_LIFETIME.from_now)
    # Il confronto passa da from_now e non da DURATION.to_i: 90 giorni di CALENDARIO scavallano il
    # cambio dell'ora legale, e la differenza vera è di un'ora più lunga (o più corta) dei 90×86400.
    expect(response.parsed_body["data"]["expires_in"])
      .to be_within(60).of((Accounts::ApiTokens::Issue::DEFAULT_LIFETIME.from_now - Time.current).to_i)
  end
end
