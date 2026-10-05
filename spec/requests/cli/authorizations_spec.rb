# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::Authorizations (approvazione device-flow)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  def sign_in_as(acc)
    post login_path, params: { email: acc.email, password: "Secret123!" }
  end

  def live_grant
    create(:device_grant, user_code: "WDJB-MZHN")
  end

  it "senza login → redirect a /login" do
    grant = live_grant
    get cli_authorize_path(user_code: grant.user_code)
    expect(response).to redirect_to(login_path)
  end

  it "loggato + user_code valido → 200 con client e selettore org" do
    sign_in_as(account)
    grant = live_grant

    get cli_authorize_path(user_code: grant.user_code)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="cli-authorize"')
    expect(response.body).to include("cli-authorize-org-#{organization.id}")
  end

  it "user_code sconosciuto → 404 con schermata 'codice non valido'" do
    sign_in_as(account)
    get cli_authorize_path(user_code: "ZZZZ-ZZZZ")

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include('data-test="cli-authorize-unknown"')
    # Icona danger: token red, non rose.
    expect(response.body).not_to include("bg-rose-50")
    expect(response.body).to include("bg-red-50")
  end

  it "il gruppo radio organization è un fieldset con legend associato (a11y) e token colore red" do
    sign_in_as(account)
    grant = live_grant

    get cli_authorize_path(user_code: grant.user_code)

    doc = Nokogiri::HTML(response.body)
    fieldset = doc.at_css("fieldset")
    expect(fieldset).to be_present
    legend = fieldset.at_css("legend")
    expect(legend).to be_present
    expect(legend.text).to include(I18n.t("cli.authorize.organization_label"))
    expect(fieldset.at_css('input[type="radio"][name="organization_id"]')).to be_present
    # Asterisco obbligatorio nel legend: token red, non rose.
    expect(response.body).not_to include("text-rose-500")
    expect(response.body).to include("text-red-500")
  end

  it "approva con org scelta → grant approvato + schermata approved" do
    sign_in_as(account)
    grant = live_grant

    post cli_authorize_approve_path(user_code: grant.user_code), params: { organization_id: organization.id }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="cli-authorize-approved"')
    grant.reload
    expect(grant).to be_approved
    expect(grant.account).to eq(account)
    expect(grant.organization).to eq(organization)
  end

  # CYRA-717 — l'accesso dura 90 giorni: si legge nel momento in cui lo si concede, non tre mesi dopo.
  it "la pagina di conferma dice quanto dura l'accesso" do
    sign_in_as(account)
    grant = live_grant

    post cli_authorize_approve_path(user_code: grant.user_code), params: { organization_id: organization.id }

    expect(response.body).to include('data-test="cli-authorize-expiry"')
    expect(response.body).to include(
      I18n.t("cli.authorize.approved_expiry", days: Accounts::Constants::API_TOKEN_DEFAULT_LIFETIME_DAYS)
    )
  end

  it "un secondo approve dello stesso utente è idempotente anche dopo il poll CLI" do
    sign_in_as(account)
    grant = live_grant
    path = cli_authorize_approve_path(user_code: grant.user_code)

    post path, params: { organization_id: organization.id }
    expect(response.body).to include('data-test="cli-authorize-approved"')
    grant.update!(status: :fulfilled)

    expect do
      post path, params: { organization_id: organization.id }
    end.not_to change(Accounts::ApiToken, :count)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="cli-authorize-approved"')
  end

  it "non tratta come retry idempotente il grant approvato da un altro account" do
    other = create(:account)
    create(:membership, account: other, organization:)
    grant = create(:device_grant, :approved, account: other, organization:)
    sign_in_as(account)

    post cli_authorize_approve_path(user_code: grant.user_code), params: { organization_id: organization.id }

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include('data-test="cli-authorize-unknown"')
  end

  it "il submit mostra feedback e viene disabilitato da Turbo" do
    sign_in_as(account)
    grant = live_grant
    get cli_authorize_path(user_code: grant.user_code)

    button = Nokogiri::HTML(response.body).at_css('[data-test="cli-authorize-approve"]')
    expect(button["data-turbo-submits-with"]).to eq(I18n.t("cli.authorize.authorizing"))
  end

  it "approva senza org → 422, grant resta pending" do
    sign_in_as(account)
    grant = live_grant

    post cli_authorize_approve_path(user_code: grant.user_code), params: { organization_id: "" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(grant.reload).to be_pending
  end

  it "approva con org non dell'account → 422 (anti-BOLA)" do
    sign_in_as(account)
    grant = live_grant
    other_org = create(:organization)

    post cli_authorize_approve_path(user_code: grant.user_code), params: { organization_id: other_org.id }

    expect(response).to have_http_status(:unprocessable_content)
    expect(grant.reload).to be_pending
  end

  it "nega → grant denied + schermata denied" do
    sign_in_as(account)
    grant = live_grant

    post cli_authorize_deny_path(user_code: grant.user_code)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="cli-authorize-denied"')
    expect(grant.reload).to be_denied
  end

  it "approve con user_code sconosciuto → 404" do
    sign_in_as(account)
    post cli_authorize_approve_path(user_code: "ZZZZ-ZZZZ"), params: { organization_id: organization.id }
    expect(response).to have_http_status(:not_found)
  end

  it "approve con grant valido ma Approve.call fallito → 422 con alert" do
    sign_in_as(account)
    grant = live_grant
    allow(Accounts::Devices::Approve).to receive(:call).and_return(
      Result.err(AppError.new("approvazione fallita", code: "R422-CLIAUTH-009", status: :unprocessable_content))
    )

    post cli_authorize_approve_path(user_code: grant.user_code), params: { organization_id: organization.id }

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "deny con user_code vuoto → schermata denied senza toccare alcun grant" do
    sign_in_as(account)
    post cli_authorize_deny_path(user_code: " ")
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="cli-authorize-denied"')
  end

  it "deny con user_code inesistente → schermata denied (nessuna azione)" do
    sign_in_as(account)
    post cli_authorize_deny_path(user_code: "ZZZZ-ZZZZ")
    expect(response).to have_http_status(:ok)
  end
end
