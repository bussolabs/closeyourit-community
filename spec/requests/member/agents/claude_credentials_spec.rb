# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Agents::ClaudeCredentials", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  context "as the owner" do
    before do
      create(:membership, account: owner, organization: org, role: :owner)
      sign_in(owner)
    end

    it "shows the empty state" do
      get member_agents_claude_credential_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.claude_credential.state_missing"))
      expect(response.body).not_to include("claude-credential-remove-dialog")
    end

    # CYRA-728: every machine uses this credential, so writing it is a confirmed, recorded action.
    it "asks for confirmation without echoing the credential, then records the confirmed write" do
      patch member_agents_claude_credential_path, params: { token: "sk-ant-api03-unconfirmed" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include("sk-ant-api03-unconfirmed")
      expect(org.reload.claude_credential).to be_nil

      expect do
        patch member_agents_claude_credential_path, params: { token: "sk-ant-api03-confirmed", confirm: "1" }
      end.to change { Authorization::Event.where(action: "dangerous_action_confirmed").count }.by(1)
      expect(org.reload.claude_credential.token).to eq("sk-ant-api03-confirmed")
    end

    it "saves an API key and never renders it back" do
      patch member_agents_claude_credential_path, params: { token: " sk-ant-api03-secretvalue ", confirm: "1" }

      expect(response).to redirect_to(member_agents_claude_credential_path)
      credential = org.reload.claude_credential
      expect(credential.token).to eq("sk-ant-api03-secretvalue")
      expect(credential.kind).to eq("api_key")
      expect(credential.set_by).to eq(owner)

      get member_agents_claude_credential_path
      expect(response.body).not_to include("sk-ant-api03-secretvalue")
      expect(response.body).to include("claude-credential-remove-dialog")
    end

    it "replaces the saved credential" do
      create(:agent_claude_credential, organization: org, token: "sk-ant-api03-old")

      patch member_agents_claude_credential_path, params: { token: "sk-ant-oat01-new", confirm: "1" }

      expect(org.reload.claude_credential.token).to eq("sk-ant-oat01-new")
      expect(Agents::ClaudeCredential.where(organization: org).count).to eq(1)
    end

    it "rejects a value that is not a Claude credential and keeps the old one" do
      create(:agent_claude_credential, organization: org, token: "sk-ant-api03-kept")

      patch member_agents_claude_credential_path, params: { token: "ghp_wrong", confirm: "1" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("member.claude_credential.update.invalid"))
      expect(response.body).not_to include("ghp_wrong")
      expect(org.reload.claude_credential.token).to eq("sk-ant-api03-kept")
    end

    it "does nothing on a blank field" do
      create(:agent_claude_credential, organization: org, token: "sk-ant-api03-kept")

      patch member_agents_claude_credential_path, params: { token: "  ", confirm: "1" }

      expect(response).to redirect_to(member_agents_claude_credential_path)
      expect(flash[:notice]).to eq(I18n.t("member.claude_credential.update.unchanged"))
      expect(org.reload.claude_credential.token).to eq("sk-ant-api03-kept")
    end

    it "asks for a credential on a blank field when none is saved" do
      patch member_agents_claude_credential_path, params: { token: "", confirm: "1" }

      expect(flash[:alert]).to eq(I18n.t("member.claude_credential.update.missing"))
      expect(org.reload.claude_credential).to be_nil
    end

    it "removes the credential" do
      create(:agent_claude_credential, organization: org)

      delete member_agents_claude_credential_path, params: { confirm: "1" }

      expect(response).to redirect_to(member_agents_claude_credential_path)
      expect(org.reload.claude_credential).to be_nil
    end

    # CYRA-1052 — instead of pasting, the owner links a secret already in a vault.
    it "links the owner's personal secret and offers it on the page" do
      variable = create(:personal_secret_variable, organization: org, account: owner, name: "CLAUDE_CODE_OAUTH_TOKEN",
                                                   value: "sk-ant-oat01-personal")

      get member_agents_claude_credential_path
      expect(response.body).to include("CLAUDE_CODE_OAUTH_TOKEN")

      patch member_agents_claude_credential_path, params: { token: "", secret: "personal:#{variable.id}", confirm: "1" }

      expect(response).to redirect_to(member_agents_claude_credential_path)
      credential = org.reload.claude_credential
      expect(credential).to have_attributes(personal_variable: variable, token: nil, set_by: owner, kind: "oauth_token")
      get member_agents_claude_credential_path
      expect(response.body).not_to include("sk-ant-oat01-personal")
    end

    it "links a shared secret of the organization" do
      environment = create(:environment, organization: org)
      variable = Secrets::Shared::Variable.create!(organization: org, name: "ANTHROPIC_API_KEY")
      value = Secrets::Shared::Value.create!(shared_variable: variable, environment:, value: "sk-ant-api03-shared")

      patch member_agents_claude_credential_path, params: { secret: "shared:#{value.id}", confirm: "1" }

      expect(org.reload.claude_credential.shared_value).to eq(value)
    end

    it "replaces a linked secret with a pasted key" do
      variable = create(:personal_secret_variable, organization: org, account: owner, value: "sk-ant-oat01-linked")
      create(:agent_claude_credential, organization: org, token: nil, personal_variable: variable, set_by: owner)

      patch member_agents_claude_credential_path, params: { token: "sk-ant-api03-pasted", secret: "personal:#{variable.id}", confirm: "1" }

      expect(org.reload.claude_credential).to have_attributes(token: "sk-ant-api03-pasted", personal_variable: nil)
    end

    it "never links another member's personal secret" do
      other = create(:membership, organization: org).account
      variable = create(:personal_secret_variable, organization: org, account: other, value: "sk-ant-oat01-notyours")

      patch member_agents_claude_credential_path, params: { secret: "personal:#{variable.id}", confirm: "1" }

      expect(org.reload.claude_credential).to be_nil
    end

    it "links the page from the machines list" do
      get member_agents_path

      expect(response.body).to include("agents-claude-credential-link")
    end
  end

  context "as an admin who is not the owner" do
    let(:admin) { create(:account) }

    before do
      create(:membership, account: owner, organization: org, role: :owner)
      create(:membership, account: admin, organization: org, role: :admin)
      sign_in(admin)
    end

    it "cannot open, set or remove the credential" do
      create(:agent_claude_credential, organization: org, token: "sk-ant-api03-owners")

      get member_agents_claude_credential_path
      expect(response).to redirect_to(root_path)

      patch member_agents_claude_credential_path, params: { token: "sk-ant-api03-hijack", confirm: "1" }
      delete member_agents_claude_credential_path, params: { confirm: "1" }

      expect(org.reload.claude_credential.token).to eq("sk-ant-api03-owners")
    end

    it "does not see the link on the machines list" do
      get member_agents_path

      expect(response.body).not_to include("agents-claude-credential-link")
    end
  end
end
