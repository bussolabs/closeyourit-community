# frozen_string_literal: true

FactoryBot.define do
  factory :product_category, class: "Product::Category" do
    association :group
    # L'org è denormalizzata ma deve combaciare con quella del gruppo (validazione di coerenza).
    organization { group.organization }
    sequence(:name) { |n| "Category #{n}" }
    position { 0 }
  end
end
