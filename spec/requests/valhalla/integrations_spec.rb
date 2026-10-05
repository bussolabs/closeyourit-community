# frozen_string_literal: true

require "rails_helper"

# CYRA-914 phase 2 — GitHub App and Telegram values set from Valhalla, encrypted, the environment as
# fallback. Secrets are never shown back, except a webhook secret right after it is generated.
RSpec.describe "Valhalla::Integrations", type: :request do
  def sign_in_as(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  let(:god) { create(:account, god: true) }
  let(:settings) { Settings::Global.instance }

  around do |example|
    names = Settings::Integrations::FIELDS.values
    saved = names.index_with { |name| ENV.fetch(name, nil) }
    names.each { |name| ENV.delete(name) }
    example.run
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  it "is for gods only" do
    sign_in_as(create(:account))
    get valhalla_integrations_path
    expect(response).to redirect_to(root_path)
  end

  it "says where each value comes from and never shows a secret" do
    ENV["TELEGRAM_BOT_TOKEN"] = "123:env-telegram-secret"
    settings.update!(gh_app_id: "4242", gh_app_private_key: "-----PEM-valhalla-secret-----")
    sign_in_as(god)

    get valhalla_integrations_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="integration-source-telegram_bot_token-environment"')
    expect(response.body).to include('data-test="integration-source-gh_app_private_key-valhalla"')
    expect(response.body).to include('data-test="integration-source-gh_webhook_secret-missing"')
    expect(response.body).to include("4242")
    expect(response.body).not_to include("env-telegram-secret", "PEM-valhalla-secret")
  end

  it "saves the values and keeps a stored secret when its field is left empty" do
    settings.update!(gh_app_client_secret: "kept-secret")
    sign_in_as(god)

    patch valhalla_integrations_path, params: { gh_app_id: "99", gh_app_client_secret: "", telegram_bot_username: "cyi_bot" }

    expect(response).to redirect_to(valhalla_integrations_path)
    expect(settings.reload).to have_attributes(gh_app_id: "99", gh_app_client_secret: "kept-secret",
                                               telegram_bot_username: "cyi_bot")
  end

  it "generates a webhook secret, shows it once and never again" do
    sign_in_as(god)

    post generate_valhalla_integrations_path, params: { field: "telegram_webhook_secret", confirm: "1" }
    secret = settings.reload.telegram_webhook_secret

    expect(secret.length).to be >= 32
    expect(response.body).to include(secret)
    get valhalla_integrations_path
    expect(response.body).not_to include(secret)
  end

  it "shows the generated secret to a Turbo form submission, which drops a plain 200 page" do
    sign_in_as(god)

    post generate_valhalla_integrations_path, params: { field: "gh_webhook_secret", confirm: "1" },
                                              headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }

    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(response.body).to include('action="replace"', 'target="valhalla-integrations"',
                                     settings.reload.gh_webhook_secret)
  end

  it "does not let an account outside Valhalla generate a secret" do
    settings.update!(gh_webhook_secret: "current")
    sign_in_as(create(:account))

    post generate_valhalla_integrations_path, params: { field: "gh_webhook_secret", confirm: "1" }

    expect(settings.reload.gh_webhook_secret).to eq("current")
  end

  it "does not let a god without two-factor generate a secret" do
    settings.update!(gh_webhook_secret: "current")
    post login_path, params: { email: god.email, password: "Secret123!" }

    post generate_valhalla_integrations_path, params: { field: "gh_webhook_secret", confirm: "1" }

    expect(settings.reload.gh_webhook_secret).to eq("current")
  end

  it "generates only the two webhook secrets" do
    sign_in_as(god)

    post generate_valhalla_integrations_path, params: { field: "gh_app_private_key", confirm: "1" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(settings.reload.gh_app_private_key).to be_nil
  end

  it "does not replace a webhook secret without confirmation" do
    settings.update!(gh_webhook_secret: "current")
    sign_in_as(god)

    post generate_valhalla_integrations_path, params: { field: "gh_webhook_secret" }

    expect(settings.reload.gh_webhook_secret).to eq("current")
  end

  it "makes the Telegram webhook accept the secret saved in Valhalla" do
    settings.update!(telegram_webhook_secret: "valhalla-webhook-secret")

    post telegram_webhook_path, params: { update_id: 1 }.to_json,
                                headers: { "Content-Type" => "application/json",
                                           "X-Telegram-Bot-Api-Secret-Token" => "valhalla-webhook-secret" }

    expect(response).not_to have_http_status(:not_found)
  end
end
