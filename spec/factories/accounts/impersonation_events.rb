FactoryBot.define do
  factory :impersonation_event, class: "Accounts::ImpersonationEvent" do
    association :god, factory: :account, god: true
    association :account, factory: :account
    started_at { Time.current }
  end
end
