FactoryBot.define do
  factory :ticketing_scenario, class: "Ticketing::Scenario" do
    ticket
    title { Faker::Lorem.words(number: 3).join(" ") }
    step_given { Faker::Lorem.sentence }
    step_when { Faker::Lorem.sentence }
    step_then { Faker::Lorem.sentence }
    step_expected { Faker::Lorem.sentence }
  end
end
