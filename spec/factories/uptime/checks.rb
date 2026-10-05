# frozen_string_literal: true

FactoryBot.define do
  factory :uptime_check, class: "Uptime::Check" do
    association :monitor, factory: :uptime_monitor
    up { true }
    status_code { 200 }
    response_time_ms { 150 }
    checked_at { Time.current }

    trait :down do
      up { false }
      status_code { nil }
      response_time_ms { nil }
      error { "timeout" }
    end

    # Righe AGGREGATE (stessa tabella, discriminatore granularity). `checked_at` = inizio del bucket;
    # `up`/`status_code`/`response_time_ms` nil (nessun esito singolo); i contatori portano l'aggregato.
    trait :hourly do
      granularity { :hourly }
      up { nil }
      status_code { nil }
      response_time_ms { nil }
      checks_total { 60 }
      checks_up { 60 }
      avg_response_ms { 120 }
    end

    trait :daily do
      granularity { :daily }
      up { nil }
      status_code { nil }
      response_time_ms { nil }
      checks_total { 1_440 }
      checks_up { 1_440 }
      avg_response_ms { 120 }
      incidents_count { 0 }
      downtime_seconds { 0 }
    end
  end
end
