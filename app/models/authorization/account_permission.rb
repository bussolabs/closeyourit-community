# frozen_string_literal: true

module Authorization
  # Override personale di una chiave-permesso (eccezione puntuale). effect allow/deny: BATTE i ruoli
  # nel Resolver (personale > team/ruoli). Org-scoped; vale entro lo scope visibile dell'account.
  # Integrità tenant: l'account dev'essere membro dell'org.
  class AccountPermission < ApplicationRecord
    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :account_permissions
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :account_permissions

    enum :effect, { allow: 0, deny: 1 }

    validates :permission_key, presence: true,
              inclusion: { in: Authorization::Catalog.keys },
              uniqueness: { scope: [ :account_id, :organization_id ] }
    validates :effect, presence: true
    validate :account_belongs_to_organization

    private

    def account_belongs_to_organization
      return if account.blank? || organization_id.blank?

      errors.add(:account, :invalid) unless account.member_of_organization?(organization_id)
    end
  end
end
