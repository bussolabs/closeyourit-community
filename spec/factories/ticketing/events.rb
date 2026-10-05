FactoryBot.define do
  factory :ticket_event, class: "Ticketing::Event" do
    ticket
    # Org derivata dal ticket (denormalizzata sulla riga evento). Safe-nav per i test
    # che forzano ticket: nil verificando la validazione di presenza.
    organization { ticket&.project&.organization }
    # reporter è già membro dell'org del ticket → attore valido.
    actor { ticket&.reporter }
    actor_name { actor&.name }
    action { "status_changed" }
    data { { "status" => { "from" => "Aperto", "to" => "In corso" } } }

    # Evento avvenuto sotto impersonation: true_actor (god) ≠ actor (impersonato).
    trait :impersonated do
      true_actor { create(:account) }
    end
  end
end
