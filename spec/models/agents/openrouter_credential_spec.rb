# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::OpenrouterCredential do
  it "accepts an OpenRouter key and strips spaces" do
    credential = create(:agent_openrouter_credential, token: " sk-or-v1-abc123 ")

    expect(credential.token).to eq("sk-or-v1-abc123")
  end

  it "refuses a value that is not an OpenRouter key" do
    expect(build(:agent_openrouter_credential, token: "sk-ant-api03-x")).to be_invalid
    expect(build(:agent_openrouter_credential, token: "sk-or-v1-a b")).to be_invalid
  end

  it "keeps one key per organization" do
    credential = create(:agent_openrouter_credential)

    expect(build(:agent_openrouter_credential, organization: credential.organization)).to be_invalid
  end

  it "stores the key encrypted and never shows it in inspect" do
    credential = create(:agent_openrouter_credential, token: "sk-or-v1-secretvalue")

    raw = described_class.connection.select_value("SELECT token FROM agents_openrouter_credentials WHERE id = '#{credential.id}'")
    expect(raw).not_to include("sk-or-v1-secretvalue")
    expect(credential.inspect).not_to include("secretvalue")
  end
end
