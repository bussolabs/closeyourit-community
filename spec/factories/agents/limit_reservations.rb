# frozen_string_literal: true

FactoryBot.define do
  # Decisione persistita per una partenza (Agents::Limits::Reserve). `estimated_cost` è nullable di
  # proposito: le partenze senza costo tracciato sono un caso reale, ed è quello che la scheda
  # dell'host deve dichiarare invece di sommare un totale parziale.
  factory :agent_limit_reservation, class: "Agents::LimitReservation" do
    association :organization
    host { nil }
    project { nil }
    runtime { Agents::LimitPolicy::RUNTIMES.first }
    sequence(:idempotency_key) { |n| "queue-claim:spec-#{n}" }
    requested_ttl_seconds { 900 }
    outcome { "granted" }
    expires_at { 15.minutes.from_now }
    estimated_cost { "1.0000" }

    trait :denied do
      outcome { "denied" }
      expires_at { nil }
      denial_reason { "max_daily_runs" }
    end
  end
end
