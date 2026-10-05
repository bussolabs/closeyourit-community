# frozen_string_literal: true

require "rails_helper"

# CYRA-914 phase 2 — GitHub App and Telegram values: Valhalla first, the environment as fallback.
RSpec.describe Settings::Integrations do
  around do |example|
    names = described_class::FIELDS.values
    saved = names.index_with { |name| ENV.fetch(name, nil) }
    example.run
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  it "reads every value from the environment when Valhalla has none, so closeyour.it does not change" do
    described_class::FIELDS.each_value { |name| ENV[name] = "env-#{name}" }

    described_class::FIELDS.each do |field, name|
      expect(described_class.value(field)).to eq("env-#{name}")
      expect(described_class.source(field)).to eq(:environment)
    end
  end

  it "prefers the value saved in Valhalla" do
    ENV["GH_APP_ID"] = "from-env"
    Settings::Global.instance.update!(gh_app_id: "from-valhalla")

    expect(described_class.value(:gh_app_id)).to eq("from-valhalla")
    expect(described_class.source(:gh_app_id)).to eq(:valhalla)
  end

  it "says when a value is missing everywhere" do
    ENV.delete("TELEGRAM_BOT_TOKEN")

    expect(described_class.value(:telegram_bot_token)).to be_nil
    expect(described_class.source(:telegram_bot_token)).to be_nil
  end

  it "stores the secrets encrypted and never serializes them" do
    Settings::Global.instance.update!(gh_app_private_key: "-----PEM-secret-----", telegram_bot_token: "123:tg-secret")
    raw = Settings::Global.connection.select_one("SELECT gh_app_private_key, telegram_bot_token FROM settings_global")

    expect(raw.values.join).not_to include("PEM-secret", "tg-secret")
    expect(Settings::Global.instance.to_json).not_to include("PEM-secret", "tg-secret")
  end

  it "knows whether the GitHub App is complete" do
    %w[GH_APP_ID GH_APP_PRIVATE_KEY GH_APP_CLIENT_ID GH_APP_CLIENT_SECRET].each { |name| ENV.delete(name) }
    expect(described_class).not_to be_github_configured

    Settings::Global.instance.update!(gh_app_id: "1", gh_app_private_key: "k", gh_app_client_id: "c",
                                      gh_app_client_secret: "s")
    expect(described_class).to be_github_configured
  end
end
