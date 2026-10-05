# frozen_string_literal: true

FactoryBot.define do
  factory :guidance_procedure, class: "Guidance::Procedure" do
    transient do
      # Owner opzionale: se passato, l'org deriva da lui (niente mismatch tenant). Default: un progetto.
      owner { nil }
      organization do
        case owner
        when Organizations::Organization then owner
        when nil then create(:organization)
        else owner.organization
        end
      end
    end

    sequence(:key) { |n| "proc-#{n}" }
    content { Faker::Lorem.paragraph }
    application_mode { :inherit }
    merge_strategy { :override }

    after(:build) do |procedure, evaluator|
      procedure.organization ||= evaluator.organization
      procedure.owner ||= evaluator.owner || create(:project, organization: procedure.organization)
    end

    # Taglia netto la catena: vince da sola, ignora l'ereditato.
    trait :replace do
      application_mode { :replace }
    end

    # Sopprime la key ereditata (come enabled: false).
    trait :disable do
      application_mode { :disable }
    end

    # Con application_mode inherit, accoda il content del livello più vicino a quello ereditato.
    trait :append do
      merge_strategy { :append }
    end

    trait :disabled do
      enabled { false }
    end
  end
end
