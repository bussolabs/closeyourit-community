# frozen_string_literal: true

FactoryBot.define do
  factory :environment, class: "Types::Environment" do
    association :organization
    sequence(:code) { |n| "environment_#{n}" }
    label { "Environment" }
    color { "emerald" }
    position { 0 }
    # Default di capability espliciti (coerenti col default DB) così build e create combaciano.
    servers_enabled { true }
    uptime_enabled { true }
    secrets_enabled { true }
    # approval_required: default DB FALSE (a differenza delle altre 3, permissive): l'approvazione va
    # scelta esplicitamente (CYRA-138, Fase 4 pezzo C1a), mai subita.
    approval_required { false }

    trait(:servers_off) { servers_enabled { false } }
    trait(:uptime_off) { uptime_enabled { false } }
    trait(:secrets_off) { secrets_enabled { false } }
  end
end
