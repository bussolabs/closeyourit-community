# frozen_string_literal: true

require "rails_helper"

# CYAU-228 — the owner lends one OpenRouter key to the machines; nobody can read it back.
RSpec.describe "Member::Agents::OpenrouterCredentials", type: :request do
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

    it "saves a key and never renders it back" do
      get member_agents_openrouter_credential_path
      expect(response).to have_http_status(:ok)

      patch member_agents_openrouter_credential_path, params: { token: " sk-or-v1-secretvalue ", confirm: "1" }

      expect(response).to redirect_to(member_agents_openrouter_credential_path)
      expect(org.reload.openrouter_credential).to have_attributes(token: "sk-or-v1-secretvalue", set_by: owner)
      get member_agents_openrouter_credential_path
      expect(response.body).not_to include("sk-or-v1-secretvalue")
      expect(response.body).to include("openrouter-credential-remove-dialog")
    end

    it "keeps the saved key when the field is empty" do
      create(:agent_openrouter_credential, organization: org, token: "sk-or-v1-kept")

      patch member_agents_openrouter_credential_path, params: { token: "", confirm: "1" }

      expect(response).to redirect_to(member_agents_openrouter_credential_path)
      expect(org.reload.openrouter_credential.token).to eq("sk-or-v1-kept")
    end

    it "refuses a value that is not an OpenRouter key and keeps the old one" do
      create(:agent_openrouter_credential, organization: org, token: "sk-or-v1-kept")

      patch member_agents_openrouter_credential_path, params: { token: "sk-ant-api03-wrong", confirm: "1" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(org.reload.openrouter_credential.token).to eq("sk-or-v1-kept")
      expect(response.body).not_to include("sk-ant-api03-wrong")
    end

    it "removes the key" do
      create(:agent_openrouter_credential, organization: org)

      delete member_agents_openrouter_credential_path, params: { confirm: "1" }

      expect(response).to redirect_to(member_agents_openrouter_credential_path)
      expect(org.reload.openrouter_credential).to be_nil
    end
  end

  context "as an admin who is not the owner" do
    let(:admin) { create(:account) }

    before do
      create(:membership, account: admin, organization: org, role: :admin)
      sign_in(admin)
    end

    it "cannot open or change the key" do
      get member_agents_openrouter_credential_path
      expect(response).to redirect_to(root_path)

      patch member_agents_openrouter_credential_path, params: { token: "sk-or-v1-x", confirm: "1" }
      expect(org.reload.openrouter_credential).to be_nil
    end
  end
end
