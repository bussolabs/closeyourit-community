FactoryBot.define do
  factory :project, class: "Projects::Project" do
    association :organization
    name { Faker::App.name }
    # Key esplicita e univoca, max 4 caratteri (vincolo del model). Base-36 → resta ≤4 char
    # fino a n=46655 ("PZZZ"), così non sfora anche con migliaia di progetti creati in un run.
    sequence(:key) { |n| "P#{n.to_s(36).upcase}" }
  end
end
