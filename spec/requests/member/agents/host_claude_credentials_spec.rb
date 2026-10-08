# frozen_string_literal: true

require "rails_helper"

# CYRA-1052 — one machine can have its own Claude credential, pasted or linked from a vault secret.
RSpec.describe "Member::Agents::HostClaudeCredentials", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:host) { create(:agent_host, organization: org) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  context "as the owner" do
    before do
      create(:membership, account: owner, organization: org, role: :owner)
      sign_in(owner)
    end

    it "shows the machine's credential panel on the details tab" do
      get member_agent_path(host, tab: "details")

      expect(response.body).to include("host-claude-credential")
    end

    it "saves a pasted credential for this machine only" do
      patch member_agent_claude_credential_path(host), params: { token: "sk-ant-api03-machine", confirm: "1" }

      expect(response).to redirect_to(member_agent_path(host, tab: "details"))
      expect(host.reload.claude_credential).to have_attributes(token: "sk-ant-api03-machine", set_by: owner)
      expect(org.reload.claude_credential).to be_nil
    end

    it "links the owner's personal secret to the machine" do
      variable = create(:personal_secret_variable, organization: org, account: owner, value: "sk-ant-oat01-lent")

      patch member_agent_claude_credential_path(host), params: { secret: "personal:#{variable.id}", confirm: "1" }

      expect(host.reload.claude_credential.personal_variable).to eq(variable)
    end

    it "rejects a value that is not a Claude credential" do
      patch member_agent_claude_credential_path(host), params: { token: "ghp_wrong", confirm: "1" }

      expect(response).to redirect_to(member_agent_path(host, tab: "details"))
      expect(flash[:alert]).to eq(I18n.t("member.claude_credential.update.invalid"))
      expect(host.reload.claude_credential).to be_nil
    end

    it "removes the machine's credential, the organization's stays" do
      create(:agent_claude_credential, organization: org, host:)
      create(:agent_claude_credential, organization: org)

      delete member_agent_claude_credential_path(host), params: { confirm: "1" }

      expect(host.reload.claude_credential).to be_nil
      expect(org.reload.claude_credential).to be_present
    end

    it "does not touch a machine of another organization" do
      foreign = create(:agent_host)

      patch member_agent_claude_credential_path(foreign), params: { token: "sk-ant-api03-foreign", confirm: "1" }

      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.claude_credential).to be_nil
    end
  end

  context "as an admin who is not the owner" do
    let(:admin) { create(:account) }

    before do
      create(:membership, account: owner, organization: org, role: :owner)
      create(:membership, account: admin, organization: org, role: :admin)
      sign_in(admin)
    end

    it "can neither see nor set the machine's credential" do
      get member_agent_path(host, tab: "details")
      expect(response.body).not_to include("host-claude-credential")

      patch member_agent_claude_credential_path(host), params: { token: "sk-ant-api03-hijack", confirm: "1" }

      expect(host.reload.claude_credential).to be_nil
    end
  end
end
