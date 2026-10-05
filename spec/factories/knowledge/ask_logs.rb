# frozen_string_literal: true

FactoryBot.define do
  # Voce di storico "Chiedi alla KB" (CYRA-421): domanda posta dal team con la risposta e lo snapshot
  # dello scope su cui è stata eseguita (per la visibilità, come le pagine).
  factory :knowledge_ask_log, class: "Knowledge::AskLog" do
    association :organization
    account do
      create(:account).tap do |a|
        create(:membership, account: a, organization: organization, role: :member)
      end
    end
    question { "Che decisione abbiamo preso sul database?" }
    answer { "Abbiamo scelto PostgreSQL per il supporto nativo agli array e a pgvector." }
    insufficient { false }
    full_access { false }
    project_ids { [] }
    group_ids { [] }
    citations { [] }

    # Domanda a cui la KB non sapeva rispondere: risposta assente, marcata insufficiente.
    trait :insufficient do
      insufficient { true }
      answer { nil }
    end

    # Posta da un owner/god sull'intera org: visibile solo a chi ha accesso pieno.
    trait :org_wide do
      full_access { true }
    end
  end
end
