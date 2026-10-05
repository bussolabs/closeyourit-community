# frozen_string_literal: true

FactoryBot.define do
  factory :feature_platform, class: "Connections::FeaturePlatform" do
    association :feature, factory: :product_feature
    # Piattaforma e stato devono essere della stessa org della funzionalità (validazioni tenant).
    platform { association(:platform, organization: feature.organization) }
    status { association(:feature_status, organization: feature.organization) }
  end
end
