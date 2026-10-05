FactoryBot.define do
  factory :group, class: "Projects::Group" do
    association :organization
    sequence(:name) { |n| "Group #{n}" }
    color { "indigo" }
  end
end
