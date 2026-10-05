FactoryBot.define do
  factory :project_membership, class: "Connections::ProjectMembership" do
    association :project
    association :account

    # Integrità tenant: l'account dev'essere membro dell'org del progetto (validato sul model).
    after(:build) do |pm|
      next if pm.project.blank? || pm.account.blank?

      pm.account.save! if pm.account.new_record?
      # member_of_organization? (memoizzato sull'account) invece di un exists? per ogni project_membership:
      # collegare N progetti allo stesso membro faceva scattare N connections_memberships exists? identiche.
      create(:membership, account: pm.account, organization: pm.project.organization) unless pm.account.member_of_organization?(pm.project.organization_id)
    end
  end
end
