# frozen_string_literal: true

FactoryBot.define do
  factory :role, class: "Authorization::Role" do
    organization
    sequence(:name) { |n| "Role #{n}" }
  end

  factory :role_permission, class: "Authorization::RolePermission" do
    association :role
    permission_key { "tickets.edit" }
  end

  factory :team_role, class: "Authorization::TeamRole" do
    association :team
    role { association(:role, organization: team.organization) }
  end

  # Associazioni PERSISTITE (l'account è già membro dell'org), record buildato: niente after(:build)
  # né autosave del join (che inserirebbe FK null / chiavi invalide durante account.save!).
  factory :account_role, class: "Authorization::AccountRole" do
    transient { member_org { create(:organization) } }
    organization { member_org }
    account do
      create(:account).tap { |acc| create(:membership, account: acc, organization: member_org) }
    end
    role { create(:role, organization: member_org) }
  end

  factory :account_permission, class: "Authorization::AccountPermission" do
    transient { member_org { create(:organization) } }
    organization { member_org }
    account do
      create(:account).tap { |acc| create(:membership, account: acc, organization: member_org) }
    end
    permission_key { "tickets.edit" }
    effect { :allow }
  end

  factory :authorization_event, class: "Authorization::Event" do
    organization
    action { "permission_granted" }
  end
end
