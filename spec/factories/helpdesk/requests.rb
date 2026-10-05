FactoryBot.define do
  factory :helpdesk_request, class: "Helpdesk::Request" do
    transient do
      organization { create(:organization) }
      body { "The checkout fails when I pay by card." }
    end

    project { create(:project, organization: organization, helpdesk_enabled: true) }
    summary { body.truncate(Helpdesk::Constants::SUMMARY_MAX_CHARS) }
    sequence(:email) { |n| "visitor#{n}@example.com" }
    page_url { "https://shop.example.com/cart" }
    browser { "Safari" }
    os { "iOS" }
    device_type { "mobile" }

    after(:create) do |request, evaluator|
      create(:helpdesk_message, request: request, body: evaluator.body)
    end

    trait :discarded do
      status { :discarded }
      discarded_at { Time.current }
    end
  end

  factory :helpdesk_message, class: "Helpdesk::Message" do
    association :request, factory: :helpdesk_request
    direction { :inbound }
    body { "The checkout fails when I pay by card." }
  end
end
