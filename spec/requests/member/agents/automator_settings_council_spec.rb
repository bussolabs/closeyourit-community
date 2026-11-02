# frozen_string_literal: true

require "rails_helper"

# CYRA-1133 — the council's master switch and its last rounds.
RSpec.describe "Automator council settings", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "saves the council mode" do
    patch member_agents_automator_setting_path, params: { work_engine: "claude", reviewer: "codex", council_mode: "dry_run", confirm: "1" }
    expect(Agents::AutomatorSetting.find_by(organization:).council_mode).to eq("dry_run")
  end

  it "lists the last council rounds" do
    create(:agent_council_run, organization:, status: "completed", report: { "outcomes" => { "ticket" => 1 } })
    get member_agents_automator_setting_path
    expect(response.body).to include('data-test="council-run"')
  end
end
