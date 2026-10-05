# frozen_string_literal: true

# CYRA-604 — una riga del registro di cosa il sistema ha guardato.
#
# La factory di partenza è `pending` DI PROPOSITO: è come la riga nasce davvero, prima che qualcuno
# sia andato a guardare. Una factory che nascesse già verificata renderebbe verdi le prove sul ramo
# «mai guardato», che è il ramo che questo registro esiste per tenere distinto.
FactoryBot.define do
  factory :agent_delivery_candidate, class: "Agents::DeliveryCandidate" do
    transient { organization { FactoryReuse.organization } }

    workflow { create(:agent_workflow, organization:) }
    attempt { create(:agent_attempt, workflow:, phase: "autopilot") }
    repository_full_name { "bussolabs/closeyourit-rails" }
    sequence(:number) { |n| n + 1 }
    state { :pending }

    # `checks_payload` resta NULL: «mai guardato». Non è una dimenticanza, è il valore giusto.

    trait :verified_passing do
      state { :verified_passing }
      head_sha { "d" * 40 }
      base_ref { "main" }
      verified_at { Time.current }
      checks_payload { [ { "name" => "ci", "conclusion" => "success" } ] }
      # Gemello di `checks_payload`: Verify scrive sempre i due insieme, e una riga che dice «un
      # controllo verde, zero controlli contati» non esiste in produzione.
      checks_count { 1 }
    end

    # «Ho guardato, e di controlli non ce n'è nessuno configurato»: l'elenco VUOTO, che è una risposta.
    trait :verified_none_configured do
      state { :verified_none_configured }
      head_sha { "d" * 40 }
      base_ref { "main" }
      verified_at { Time.current }
      checks_payload { [] }
    end

    trait :unreachable do
      state { :unreachable }
      last_error_code { "R502-GITHUB-001" }
      next_check_at { 5.minutes.from_now }
    end

    trait :rejected do
      state { :rejected }
      repository_full_name { "qualcunaltro/repo-non-mio" }
      last_error_code { "R404-REPO-001" }
    end
  end
end
