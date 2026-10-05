# frozen_string_literal: true

FactoryBot.define do
  # Seme di una domanda d'esempio (CYRA-421): il giro notturno lo produce dalle pagine reali. Tiene
  # titolo + tipo, la domanda si compone a display via i18n. L'org deriva dal progetto (stesso tenant).
  factory :knowledge_sample_question, class: "Knowledge::SampleQuestion" do
    association :project
    organization { project.organization }
    title { Faker::Lorem.sentence }
    kind { :note }
    position { 0 }

    trait :decision do
      kind { :decision }
    end

    trait :guide do
      kind { :guide }
    end
  end
end
