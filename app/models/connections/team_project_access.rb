# frozen_string_literal: true

module Connections
  # Scope del team su un singolo progetto: i membri del team ottengono i permessi dei ruoli del
  # team su questo progetto. Integrità tenant: il progetto deve appartenere all'org del team (BOLA).
  class TeamProjectAccess < ApplicationRecord
    belongs_to :team,
               class_name: "Teams::Team",
               inverse_of: :project_accesses
    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :team_accesses

    validates :team_id, uniqueness: { scope: :project_id }
    validate :project_belongs_to_team_organization

    private

    def project_belongs_to_team_organization
      return if team.blank? || project.blank?

      errors.add(:project, :invalid) if project.organization_id != team.organization_id
    end
  end
end
