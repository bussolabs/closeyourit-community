FactoryBot.define do
  factory :todo_list, class: "Todos::List" do
    association :account
    association :organization
    sequence(:name) { |n| "List #{n}" }
    color { nil }
    position { 0 }
  end

  factory :todo_item, class: "Todos::Item" do
    association :list, factory: :todo_list
    sequence(:title) { |n| "Item #{n}" }
    done { false }
    position { 0 }

    trait :done do
      done { true }
      completed_at { Time.current }
    end
  end

  # Destinatario = membro dell'org della lista (richiesto dall'isolamento tenant), diverso dal proprietario.
  factory :todo_share, class: "Todos::Share" do
    association :list, factory: :todo_list
    account do
      create(:account).tap do |recipient|
        create(:membership, account: recipient, organization: list.organization, role: :member)
      end
    end
  end
end
