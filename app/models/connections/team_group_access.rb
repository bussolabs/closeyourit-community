# frozen_string_literal: true

module Connections
  # Scope del team su un gruppo-di-progetti: i membri del team ottengono i permessi dei ruoli del
  # team su TUTTI i progetti del gruppo (presenti e futuri). Integrità tenant: il gruppo deve
  # appartenere all'org del team (BOLA).
  class TeamGroupAccess < ApplicationRecord
    belongs_to :team,
               class_name: "Teams::Team",
               inverse_of: :group_accesses
    belongs_to :group,
               class_name: "Projects::Group",
               inverse_of: :team_accesses

    validates :team_id, uniqueness: { scope: :group_id }
    validate :group_belongs_to_team_organization

    private

    def group_belongs_to_team_organization
      return if team.blank? || group.blank?

      errors.add(:group, :invalid) if group.organization_id != team.organization_id
    end
  end
end
