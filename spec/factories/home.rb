FactoryBot.define do
  # CYRA-654 — un rimando è sempre di un account su un'org di cui è membro: la factory lo garantisce
  # da sé, così gli spec non devono ricordarselo.
  factory :home_deferral, class: "Home::Deferral" do
    association :account
    association :organization
    sequence(:card_key) { |n| "agent_plan:#{SecureRandom.uuid}-#{n}" }
    until_at { 1.day.from_now }

    trait :expired do
      until_at { 1.hour.ago }
    end
  end
end
