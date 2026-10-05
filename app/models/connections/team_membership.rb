# frozen_string_literal: true

module Connections
  # Join account ↔ team. L'account eredita i ruoli del team entro lo scope del team.
  # Integrità tenant: l'account deve avere una membership nell'org del team (come Group/ProjectMembership).
  class TeamMembership < ApplicationRecord
    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :team_memberships
    belongs_to :team,
               class_name: "Teams::Team",
               inverse_of: :team_memberships

    validates :account_id, uniqueness: { scope: :team_id }
    validate :account_belongs_to_team_organization

    private

    def account_belongs_to_team_organization
      return if account.blank? || team.blank?

      member = Connections::Membership.exists?(account_id: account_id,
                                               organization_id: team.organization_id)
      errors.add(:account, :invalid) unless member
    end
  end
end
