FactoryBot.define do
  factory :idea_case, class: "Ideas::Case" do
    idea
    sequence(:title) { |n| "Case #{n}" }
    sequence(:description) { |n| "Scenario #{n}: come l'idea aiuta in un caso concreto." }
  end
end
