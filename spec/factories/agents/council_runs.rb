# frozen_string_literal: true

FactoryBot.define do
  factory :agent_council_run, class: "Agents::CouncilRun" do
    association :organization
    project { association :project, organization: }
    host { association :agent_host, organization: }
    mode { "on" }
    status { "running" }
    started_at { Time.current }
  end
end
