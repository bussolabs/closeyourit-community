FactoryBot.define do
  factory :invitation, class: "Connections::Invitation" do
    organization
    invited_by factory: :account
    sequence(:email) { |n| "invitee#{n}@example.com" }
    role { :member }
    accepted_at { nil }
  end
end
