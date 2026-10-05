FactoryBot.define do
  factory :group_membership, class: "Connections::GroupMembership" do
    association :group
    association :account

    # Integrità tenant: l'account dev'essere membro dell'org del gruppo (validato sul model).
    # Garantiamo la membership così che la factory di default produca sempre un record valido
    # (richiesto da FactoryBot.lint).
    after(:build) do |gm|
      next if gm.group.blank? || gm.account.blank?

      gm.account.save! if gm.account.new_record?
      # member_of_organization? memoizzato: collegare N gruppi allo stesso membro non ripete l'exists?.
      create(:membership, account: gm.account, organization: gm.group.organization) unless gm.account.member_of_organization?(gm.group.organization_id)
    end
  end
end
