FactoryBot.define do
  factory :organization, class: "Organizations::Organization" do
    name { Faker::Company.name }
    sequence(:slug) { |n| "org-#{n}" }
  end
end
