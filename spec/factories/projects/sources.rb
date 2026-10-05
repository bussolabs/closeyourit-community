# frozen_string_literal: true

FactoryBot.define do
  factory :project_source, class: "Projects::Source" do
    association :project
    tool_code { "closeyourit-ruby" }
    version { "0.4.0" }
    first_seen_at { Time.current }
    last_seen_at { Time.current }
    events_count { 1 }
  end
end
