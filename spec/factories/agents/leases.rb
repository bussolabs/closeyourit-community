FactoryBot.define do
  factory :agent_lease, class: "Agents::Lease" do
    host { create(:agent_host) }
    organization { host.organization }
    ticket { create(:ticket, organization: host.organization) }
    sequence(:run_id) { |n| "run-#{n}" }
    agent { "triage" }
    expires_at { 1.hour.from_now }

    # Lease host-first (CYAU-96): nessuno slug agent, fase e impronta del profilo pinnate.
    trait :host_first do
      agent { nil }
      execution_phase { "triage" }
      profile_digest { Agents::PhaseProfile.for("triage").digest }
    end

    # Lease di un account (CYRA-293): presa in carico dichiarata da una persona o da un service account
    # via CLI. Nessuna identità di lavoro agente — il titolare non esegue fasi.
    trait :held_by_account do
      host { nil }
      agent { nil }
      organization { create(:organization) }
      account { create(:membership, organization: organization).account }
      ticket { create(:ticket, organization: organization) }
    end
  end
end
