FactoryBot.define do
  factory :ticketing_condition, class: "Ticketing::Condition" do
    ticket
    text { Faker::Lorem.sentence }
  end
end
