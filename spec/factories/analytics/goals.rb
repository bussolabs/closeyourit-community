# frozen_string_literal: true

FactoryBot.define do
  factory :analytics_goal, class: "Analytics::Goal" do
    project
    kind { :pageview_path }
    path_pattern { "/pricing" }
    display_name { "Visita pricing" }

    trait :custom_event do
      kind { :custom_event }
      path_pattern { nil }
      sequence(:event_name) { |n| "Signup#{n}" }
    end
  end
end
