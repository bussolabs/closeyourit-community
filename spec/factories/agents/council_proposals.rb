# frozen_string_literal: true

FactoryBot.define do
  factory :agent_council_proposal, class: "Agents::CouncilProposal" do
    association :council_run, factory: :agent_council_run
    organization { council_run.organization }
    project { council_run.project }
    sequence(:ref) { |n| "claude-#{n}" }
    proposer { "claude" }
    title { "Cache the project list" }
    problem { "The project list query is slow." }
    outcome { "rejected" }
  end
end
