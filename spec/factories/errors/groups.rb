# frozen_string_literal: true

FactoryBot.define do
  factory :error_group, class: "Errors::Group" do
    association :project
    sequence(:fingerprint) { |n| "fingerprint-#{n}" }
    title { "RuntimeError: boom" }
    culprit { "App::Widget#render" }
    level { :error }
    status { :unresolved }
    events_count { 1 }
    users_count { 0 }
    # CYRA-380: fatto storico «ha ricevuto contesto utente». Di norma allineato a users_count (chi ha
    # contato utenti li ha tracciati); i test possono forzarlo per il caso disaccoppiato post-split.
    user_context_seen { users_count.positive? }
    first_seen_at { Time.current }
    last_seen_at { Time.current }

    trait :resolved do
      status { :resolved }
    end

    trait :ignored do
      status { :ignored }
    end

    # CYRA-49: il gruppo ha visto almeno un crash non gestito (mechanism.handled=false).
    trait :unhandled do
      has_unhandled { true }
    end
  end
end
