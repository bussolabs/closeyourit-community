module Connections
  # Join account ↔ gruppo: dà accesso a TUTTI i progetti del gruppo (presenti e futuri).
  # Integrità tenant: l'account deve avere una membership nell'org del gruppo.
  class GroupMembership < ApplicationRecord
    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :group_memberships
    belongs_to :group,
               class_name: "Projects::Group",
               inverse_of: :group_memberships

    validates :account_id, uniqueness: { scope: :group_id }
    validate :account_belongs_to_group_organization

    private

    def account_belongs_to_group_organization
      return if account.blank? || group.blank?

      member = Connections::Membership.exists?(account_id: account_id,
                                               organization_id: group.organization_id)
      errors.add(:account, :invalid) unless member
    end
  end
end
