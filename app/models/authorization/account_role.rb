# frozen_string_literal: true

module Authorization
  # Ruolo assegnato DIRETTAMENTE a un utente singolo (senza per forza un team). organization_id è
  # denormalizzato per query per-org. Integrità tenant: il ruolo dev'essere dell'org indicata e
  # l'account dev'essere membro dell'org (BOLA).
  class AccountRole < ApplicationRecord
    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :account_roles
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :account_roles
    belongs_to :role,
               class_name: "Authorization::Role",
               inverse_of: :account_roles

    validates :account_id, uniqueness: { scope: :role_id }
    validate :role_matches_organization
    validate :account_belongs_to_organization

    private

    def role_matches_organization
      return if role.blank? || organization_id.blank?

      errors.add(:role, :invalid) if role.organization_id != organization_id
    end

    def account_belongs_to_organization
      return if account.blank? || organization_id.blank?

      member = Connections::Membership.exists?(account_id: account_id, organization_id: organization_id)
      errors.add(:account, :invalid) unless member
    end
  end
end
