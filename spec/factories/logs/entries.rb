# frozen_string_literal: true

FactoryBot.define do
  factory :log_entry, class: "Logs::Entry" do
    project { association(:project) }
    sequence(:event_id) { |n| "log-#{n}" }
    level { :info }
    message { "Something happened" }
    data { {} }
    logger_name { "application" }
    trace_id { nil }
    environment { "production" }
    release { nil }
    occurred_at { Time.current }
  end
end
