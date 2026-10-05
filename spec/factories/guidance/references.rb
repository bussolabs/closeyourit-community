# frozen_string_literal: true

FactoryBot.define do
  factory :guidance_reference, class: "Guidance::Reference" do
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

    sequence(:key) { |n| "ref-#{n}" }
    kind { :repository }
    location { "git@github.com:acme/app.git" }
    instructions { Faker::Lorem.sentence }

    after(:build) do |reference, evaluator|
      reference.organization ||= evaluator.organization
      reference.owner ||= evaluator.owner || create(:project, organization: reference.organization)
    end

    trait :knowledge_base do
      kind { :knowledge_base }
    end

    trait :url do
      kind { :url }
    end

    trait :path do
      kind { :path }
    end

    trait :required do
      required { true }
    end

    # Disabilitata = segnale di DISABLE della key nella risoluzione (vedi Guidance::Resolve).
    trait :disabled do
      enabled { false }
    end
  end
end
