# frozen_string_literal: true

FactoryBot.define do
  factory :agent_automator_setting, class: "Agents::AutomatorSetting" do
    organization
    work_engine { "claude" }
    reviewer { "codex" }
  end
end
