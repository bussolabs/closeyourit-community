# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::AutomatorSetting do
  it "accepts only known engines" do
    expect(build(:agent_automator_setting, work_engine: "nobody")).to be_invalid
    expect(build(:agent_automator_setting, reviewer: "nobody")).to be_invalid
    expect(build(:agent_automator_setting, work_engine: "codex", reviewer: "codex")).to be_valid
  end

  # CYAU-228
  it "accepts OpenCode only as reviewer" do
    expect(build(:agent_automator_setting, reviewer: "opencode", opencode_model: "anthropic/claude-sonnet-4.5")).to be_valid
    expect(build(:agent_automator_setting, work_engine: "opencode")).to be_invalid
  end

  # CYAU-228 — the OpenRouter model OpenCode reviews with.
  it "accepts an OpenRouter model id and refuses anything else" do
    expect(build(:agent_automator_setting, opencode_model: "anthropic/claude-sonnet-4.5")).to be_valid
    expect(build(:agent_automator_setting, opencode_model: "openai/gpt-oss-20b:free")).to be_valid
    expect(build(:agent_automator_setting, opencode_model: "no-provider")).to be_invalid
    expect(build(:agent_automator_setting, opencode_model: "a/b c")).to be_invalid
  end

  it "needs a model when the organization reviews with OpenCode" do
    expect(build(:agent_automator_setting, reviewer: "opencode", opencode_model: nil)).to be_invalid
  end

  it "keeps the model while a machine reviews with OpenCode on its own choice" do
    setting = create(:agent_automator_setting, opencode_model: "anthropic/claude-sonnet-4.5")
    create(:agent_host, organization: setting.organization, work_engine: "claude", reviewer: "opencode")

    expect(setting.update(opencode_model: "")).to be(false)
    expect(setting.errors).to include(:opencode_model)
  end

  it "keeps one choice per organization" do
    setting = create(:agent_automator_setting)

    expect(build(:agent_automator_setting, organization: setting.organization)).to be_invalid
  end

  describe ".for" do
    it "returns the organization's choice" do
      setting = create(:agent_automator_setting, work_engine: "codex", reviewer: "claude")

      expect(described_class.for(setting.organization)).to have_attributes(work_engine: "codex", reviewer: "claude")
    end

    it "falls back to Claude working and Codex reviewing when the organization never chose" do
      organization = create(:organization)

      expect(described_class.for(organization)).to have_attributes(work_engine: "claude", reviewer: "codex", persisted?: false)
    end
  end
  # CYAU-235 — the supporter has its own engine; Codex unless the organization chooses.
  it "gives the supporter its own engine, Codex by default" do
    expect(described_class.new.supporter).to eq("codex")
    expect(build(:agent_automator_setting, supporter: "claude")).to be_valid
    expect(build(:agent_automator_setting, supporter: "nobody")).to be_invalid
  end

  it "keeps the reserved topics as clean lines, at most 100 characters each" do
    setting = build(:agent_automator_setting, supporter_reserved_topics: "  stripe \n\nstripe\nPayPal")
    expect(setting.supporter_reserved_topic_list).to eq(%w[stripe paypal])
    expect(build(:agent_automator_setting, supporter_reserved_topics: "x" * 101)).to be_invalid
  end
end
