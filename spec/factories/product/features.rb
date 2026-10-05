# frozen_string_literal: true

FactoryBot.define do
  factory :product_feature, class: "Product::Feature" do
    association :category, factory: :product_category
    organization { category.organization }
    sequence(:name) { |n| "Feature #{n}" }
    position { 0 }

    # Funzionalità documentata da una pagina della base di conoscenza.
    trait :documented do
      knowledge_page { association(:knowledge_page, organization: category.organization) }
    end
  end
end
