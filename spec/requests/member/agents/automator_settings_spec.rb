# frozen_string_literal: true

require "rails_helper"

# CYAU-227 — who works and who reviews, chosen once for the whole organization.
RSpec.describe "Member::Agents::AutomatorSettings", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  context "with agents.manage" do
    before do
      create(:membership, account: owner, organization:, role: :owner)
      sign_in(owner)
    end

    it "shows the default choice and which machines have their own" do
      create(:agent_host, organization:, hostname: "follower")
      create(:agent_host, organization:, hostname: "rebel", work_engine: "codex", reviewer: "claude")

      get member_agents_automator_setting_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="automator-settings-form"')
      expect(response.body).to include("rebel")
      expect(response.body).not_to include(">follower<")
    end

    it "saves the organization's choice after confirmation, and following machines use it" do
      host = create(:agent_host, organization:)
      own = create(:agent_host, organization:, work_engine: "claude", reviewer: "codex")

      patch member_agents_automator_setting_path, params: { work_engine: "codex", reviewer: "claude" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(organization.reload.automator_setting).to be_nil

      patch member_agents_automator_setting_path, params: { work_engine: "codex", reviewer: "claude", confirm: "1" }

      expect(response).to redirect_to(member_agents_automator_setting_path)
      expect(organization.reload.automator_setting).to have_attributes(work_engine: "codex", reviewer: "claude")
      expect(host.reload).to have_attributes(effective_work_engine: "codex", effective_reviewer: "claude")
      expect(own.reload).to have_attributes(effective_work_engine: "claude", effective_reviewer: "codex")
    end

    # CYAU-228
    it "saves the OpenRouter model OpenCode reviews with" do
      patch member_agents_automator_setting_path,
            params: { work_engine: "claude", reviewer: "opencode", opencode_model: " anthropic/claude-sonnet-4.5 ", confirm: "1" }

      expect(response).to redirect_to(member_agents_automator_setting_path)
      expect(organization.reload.automator_setting).to have_attributes(reviewer: "opencode", opencode_model: "anthropic/claude-sonnet-4.5")
    end

    it "warns when OpenCode reviews but the organization has no OpenRouter key" do
      create(:agent_automator_setting, organization:, reviewer: "opencode", opencode_model: "anthropic/claude-sonnet-4.5")

      get member_agents_automator_setting_path

      expect(response.body).to include('data-test="automator-settings-openrouter-missing"')
    end

    it "refuses an unknown engine" do
      patch member_agents_automator_setting_path, params: { work_engine: "nobody", reviewer: "claude", confirm: "1" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(organization.reload.automator_setting).to be_nil
    end
    # CYAU-235
    it "saves the supporter's engine and the organization's reserved topics" do
      get member_agents_automator_setting_path
      expect(response.body).to include('data-test="automator-settings-supporter"', 'data-test="automator-settings-reserved-topics"')

      patch member_agents_automator_setting_path,
            params: { work_engine: "claude", reviewer: "codex", supporter: "claude", supporter_reserved_topics: "Stripe\npaypal", confirm: "1" }

      expect(response).to redirect_to(member_agents_automator_setting_path)
      expect(organization.reload.automator_setting).to have_attributes(supporter: "claude", supporter_reserved_topics: "stripe\npaypal")
    end

    it "refuses an unknown supporter engine" do
      patch member_agents_automator_setting_path, params: { work_engine: "claude", reviewer: "codex", supporter: "nobody", confirm: "1" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(organization.reload.automator_setting).to be_nil
    end
  end

  context "with agents.view only" do
    let(:member) { create(:account) }

    before do
      create(:membership, account: member, organization:, role: :member)
      sign_in(member)
    end

    it "cannot change the organization's choice" do
      patch member_agents_automator_setting_path, params: { work_engine: "codex", reviewer: "claude", confirm: "1" }

      expect(organization.reload.automator_setting).to be_nil
    end
  end
end
