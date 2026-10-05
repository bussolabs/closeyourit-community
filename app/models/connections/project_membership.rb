module Connections
  # Join account ↔ progetto: dà accesso SOLO a quel progetto.
  # Integrità tenant: l'account deve avere una membership nell'org del progetto.
  class ProjectMembership < ApplicationRecord
    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :project_memberships
    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :project_memberships

    validates :account_id, uniqueness: { scope: :project_id }
    validate :account_belongs_to_project_organization

    private

    def account_belongs_to_project_organization
      return if account.blank? || project.blank?

      errors.add(:account, :invalid) unless account.member_of_organization?(project.organization_id)
    end
  end
end
