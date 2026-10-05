# frozen_string_literal: true

FactoryBot.define do
  factory :team_membership, class: "Connections::TeamMembership" do
    association :team
    association :account

    # Integrità tenant: l'account dev'essere membro dell'org del team (validato sul model).
    # Garantiamo la membership così che la factory di default produca sempre un record valido.
    after(:build) do |tm|
      next if tm.team.blank? || tm.account.blank?

      tm.account.save! if tm.account.new_record?
      # member_of_organization? memoizzato: collegare N team allo stesso membro non ripete l'exists?.
      create(:membership, account: tm.account, organization: tm.team.organization) unless tm.account.member_of_organization?(tm.team.organization_id)
    end
  end
end
