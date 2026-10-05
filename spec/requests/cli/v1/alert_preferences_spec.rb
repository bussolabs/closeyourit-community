# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::AlertPreferences", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:, role: :member) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def stored_preference
    ::Alerting::Preference.find_by(account_id: account.id, organization_id: organization.id)
  end

  it "senza bearer → 401" do
    get "/cli/v1/alert_preferences"
    expect(response).to have_http_status(:unauthorized)
  end

  it "show → 200 con i toggle (default della propria org)" do
    get "/cli/v1/alert_preferences", headers: headers

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data).to include("in_app_enabled", "email_enabled", "tickets_enabled", "servers_enabled",
                            "min_level", "quiet_hours_start", "quiet_hours_end", "quiet_hours_tz")
  end

  it "update disabilita un toggle → 200 e persiste" do
    put "/cli/v1/alert_preferences", headers: headers, params: { tickets_enabled: false }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]["tickets_enabled"]).to be(false)
    expect(stored_preference.tickets_enabled).to be(false)
  end

  it "update quiet hours ON → salva start/end/tz" do
    put "/cli/v1/alert_preferences", headers: headers,
                                     params: { quiet_hours_enabled: "1", quiet_hours_start: 1320,
                                               quiet_hours_end: 480, quiet_hours_tz: "Europe/Rome" }

    expect(response).to have_http_status(:ok)
    pref = stored_preference
    expect(pref.quiet_hours_start).to eq(1320)
    expect(pref.quiet_hours_end).to eq(480)
    expect(pref.quiet_hours_tz).to eq("Europe/Rome")
  end

  # CYRA-236: via CLI min_level arriva come NOME del livello; va salvato come intero corretto.
  it "update con min_level per NOME → 200 e persiste l'intero corretto" do
    put "/cli/v1/alert_preferences", headers: headers, params: { min_level: "error" }

    expect(response).to have_http_status(:ok)
    expect(stored_preference.min_level).to eq(Errors::Group.levels["error"])
  end

  it "update con min_level per nome inesistente → 422 R422-ALERT-003" do
    put "/cli/v1/alert_preferences", headers: headers, params: { min_level: "bogus" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to eq("R422-ALERT-003")
  end

  it "update quiet hours OFF → azzera la finestra" do
    ::Alerting::Preference.create!(account_id: account.id, organization_id: organization.id,
                                   quiet_hours_start: 1320, quiet_hours_end: 480)

    put "/cli/v1/alert_preferences", headers: headers, params: { quiet_hours_enabled: "0" }

    expect(response).to have_http_status(:ok)
    pref = stored_preference
    expect(pref.quiet_hours_start).to be_nil
    expect(pref.quiet_hours_end).to be_nil
  end
end
