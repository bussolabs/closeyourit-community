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

  # CYRA-1052 — one credential for the organization and at most one per machine.
  describe "machine credentials" do
    let(:organization) { create(:organization) }
    let(:host) { create(:agent_host, organization:) }

    it "keeps a machine credential beside the organization's" do
      create(:agent_claude_credential, organization:)

      expect(build(:agent_claude_credential, organization:, host:)).to be_valid
    end

    it "keeps one credential per machine" do
      create(:agent_claude_credential, organization:, host:)

      expect(build(:agent_claude_credential, organization:, host:)).not_to be_valid
    end

    it "refuses a machine of another organization" do
      credential = build(:agent_claude_credential, organization:, host: create(:agent_host))

      expect(credential).not_to be_valid
      expect(credential.errors[:host]).to be_present
    end

    it "is not the organization's credential" do
      create(:agent_claude_credential, organization:, host:)

      expect(organization.reload.claude_credential).to be_nil
    end
  end

  # CYRA-1052 — the token can come from a vault secret instead of being pasted.
  describe "a linked vault secret" do
    let(:organization) { create(:organization) }
    let(:lender) { create(:membership, organization:).account }

    def personal(value: "sk-ant-oat01-fromvault", account: lender)
      create(:personal_secret_variable, organization:, account:, name: "CLAUDE_CODE_OAUTH_TOKEN", value:)
    end

    def shared(value: "sk-ant-api03-shared", org: organization)
      environment = create(:environment, organization: org)
      variable = Secrets::Shared::Variable.create!(organization: org, name: "ANTHROPIC_API_KEY")
      Secrets::Shared::Value.create!(shared_variable: variable, environment:, value:)
    end

    it "serves the lender's personal secret" do
      credential = create(:agent_claude_credential, organization:, token: nil, personal_variable: personal, set_by: lender)

      expect(credential.served).to eq(kind: "oauth_token", env: "CLAUDE_CODE_OAUTH_TOKEN", token: "sk-ant-oat01-fromvault")
    end

    it "follows the vault when the secret is rotated" do
      variable = personal
      credential = create(:agent_claude_credential, organization:, token: nil, personal_variable: variable, set_by: lender)

      variable.update!(value: "sk-ant-api03-rotated")

      expect(credential.reload.served).to include(kind: "api_key", token: "sk-ant-api03-rotated")
    end

    it "refuses a personal secret the lender does not own" do
      someone_else = create(:membership, organization:).account
      credential = build(:agent_claude_credential, organization:, token: nil,
                                                   personal_variable: personal(account: someone_else), set_by: lender)

      expect(credential).not_to be_valid
      expect(credential.errors[:personal_variable]).to be_present
    end

    it "stops serving a personal secret once its lender leaves the organization" do
      credential = create(:agent_claude_credential, organization:, token: nil, personal_variable: personal, set_by: lender)

      Connections::Membership.where(account: lender, organization:).delete_all

      expect(credential.reload.served).to be_nil
    end

    it "serves a shared secret of the organization" do
      credential = create(:agent_claude_credential, organization:, token: nil, shared_value: shared, set_by: lender)

      expect(credential.served).to include(kind: "api_key", token: "sk-ant-api03-shared")
    end

    it "refuses a shared secret of another organization" do
      credential = build(:agent_claude_credential, organization:, token: nil,
                                                   shared_value: shared(org: create(:organization)), set_by: lender)

      expect(credential).not_to be_valid
      expect(credential.errors[:shared_value]).to be_present
    end

    it "refuses a secret whose value is not a Claude credential" do
      credential = build(:agent_claude_credential, organization:, token: nil,
                                                   personal_variable: personal(value: "ghp_notclaude"), set_by: lender)

      expect(credential).not_to be_valid
      expect(credential.errors[:kind]).to be_present
    end

    it "takes exactly one source" do
      both = build(:agent_claude_credential, organization:, personal_variable: personal, set_by: lender)
      none = build(:agent_claude_credential, organization:, token: nil)

      expect(both).not_to be_valid
      expect(none).not_to be_valid
    end
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
