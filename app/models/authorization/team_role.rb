# frozen_string_literal: true

module Authorization
  # Ruolo assegnato a un team. Integrità tenant: il ruolo deve appartenere all'org del team (BOLA).
  class TeamRole < ApplicationRecord
    belongs_to :team,
               class_name: "Teams::Team",
               inverse_of: :team_roles
    belongs_to :role,
               class_name: "Authorization::Role",
               inverse_of: :team_roles

    validates :team_id, uniqueness: { scope: :role_id }
    validate :role_belongs_to_team_organization

    private

    def role_belongs_to_team_organization
      return if team.blank? || role.blank?

      errors.add(:role, :invalid) if role.organization_id != team.organization_id
    end
  end
end
