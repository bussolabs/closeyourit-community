# frozen_string_literal: true

FactoryBot.define do
  factory :project_source_version, class: "Projects::Source::Version" do
    association :source, factory: :project_source
    version { "0.4.0" }
    first_seen_at { Time.current }
    last_seen_at { Time.current }
  end
end
