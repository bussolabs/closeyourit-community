FactoryBot.define do
  factory :activity_event, class: "Activity::Event" do
    association :subject, factory: :project
    # Org derivata dal subject (denormalizzata). Safe-nav per i test che forzano subject: nil.
    organization { subject&.organization }
    actor { association(:account) }
    actor_name { actor&.name }
    action { "created" }
    data { {} }

    # Evento avvenuto sotto impersonation: true_actor (god) ≠ actor (impersonato).
    trait :impersonated do
      true_actor { create(:account) }
    end
  end
end
