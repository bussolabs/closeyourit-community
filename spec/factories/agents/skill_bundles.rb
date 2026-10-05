# frozen_string_literal: true

FactoryBot.define do
  factory :agent_skill_bundle, class: "Agents::SkillBundle" do
    association :organization
    repo { "bussolabs/closeyourit-skills" }
    ref { "v1.0.0" }
    version { "1.0.0" }
    digest { "a" * 40 }
  end
end
