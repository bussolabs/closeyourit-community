FactoryBot.define do
  factory :membership, class: "Connections::Membership" do
    account
    organization
    role { :member }
  end
end
