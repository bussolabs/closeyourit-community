# frozen_string_literal: true

FactoryBot.define do
  factory :uptime_incident, class: "Uptime::Incident" do
    association :monitor, factory: :uptime_monitor
    started_at { 10.minutes.ago }
    resolved_at { nil }
    # Un incident vissuto ha già annunciato ciò che gli è successo (CYRA-792): il segno di consegna
    # segue lo stato, così le prove che non parlano di avvisi non nascono con un recupero pendente.
    down_alerted_at { started_at }
    up_alerted_at { resolved_at }

    trait :resolved do
      resolved_at { 5.minutes.ago }
    end

    # Avviso di caduta scritto e mai affidato alla coda: quello che il recupero deve ripescare.
    trait :down_alert_pending do
      down_alerted_at { nil }
    end

    # Ripristino scritto e mai affidato alla coda.
    trait :up_alert_pending do
      up_alerted_at { nil }
    end

    # Incident narrato: ha una phase corrente (mostra timeline + badge phase).
    trait :narrated do
      phase { :investigating }
    end
  end
end
