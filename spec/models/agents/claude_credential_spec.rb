# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::ClaudeCredential do
  it "derives an API key from the Console prefix" do
    credential = create(:agent_claude_credential)

    expect(credential.kind).to eq("api_key")
    expect(credential.env_name).to eq("ANTHROPIC_API_KEY")
  end

  it "derives an OAuth token from the setup-token prefix" do
    credential = create(:agent_claude_credential, :oauth)

    expect(credential.kind).to eq("oauth_token")
    expect(credential.env_name).to eq("CLAUDE_CODE_OAUTH_TOKEN")
    expect(credential).to be_oauth_token
  end

  it "re-derives the kind when the token is replaced" do
    credential = create(:agent_claude_credential)

    credential.update!(token: "sk-ant-oat01-replacement")

    expect(credential.reload.kind).to eq("oauth_token")
  end

  it "rejects a value that is not a Claude credential" do
    credential = build(:agent_claude_credential, token: "ghp_notclaude")

    expect(credential).not_to be_valid
    expect(credential.errors[:kind]).to be_present
  end

  it "rejects whitespace or quotes inside the token" do
    credential = build(:agent_claude_credential, token: "sk-ant-api03-abc def")

    expect(credential).not_to be_valid
    expect(credential.errors[:token]).to be_present
  end

  it "strips surrounding whitespace from a pasted token" do
    credential = create(:agent_claude_credential, token: "  sk-ant-api03-pasted \n")

    expect(credential.token).to eq("sk-ant-api03-pasted")
  end

  it "keeps one credential per organization" do
    existing = create(:agent_claude_credential)

    duplicate = build(:agent_claude_credential, organization: existing.organization)

    expect(duplicate).not_to be_valid
  end

  it "encrypts the token at rest" do
    credential = create(:agent_claude_credential, token: "sk-ant-api03-atrest")

    raw = described_class.connection.select_value(
      "SELECT token FROM agents_claude_credentials WHERE id = #{described_class.connection.quote(credential.id)}"
    )
    expect(raw).not_to include("sk-ant-api03-atrest")
  end

  it "never prints the token in inspect" do
    credential = create(:agent_claude_credential, token: "sk-ant-api03-hidden")

    expect(credential.inspect).not_to include("sk-ant-api03-hidden")
  end
end
