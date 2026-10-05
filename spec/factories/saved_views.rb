FactoryBot.define do
  factory :saved_view do
    association :account
    association :organization
    resource_type { "tickets" }
    sequence(:name) { |n| "View #{n}" }
    filters { {} }
  end
end
