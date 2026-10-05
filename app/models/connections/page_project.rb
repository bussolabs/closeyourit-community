# frozen_string_literal: true

module Connections
  # Join N:N pagina KB ↔ progetto (gemello di Connections::BookProject). L'org di riferimento è
  # denormalizzata sulla pagina (page.organization_id), non derivata dal progetto: le pagine org-wide
  # non hanno progetto ma restano tenant-scoped.
  class PageProject < ApplicationRecord
    belongs_to :page,
               class_name: "Knowledge::Page",
               inverse_of: :page_projects
    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :page_projects

    validates :project_id, uniqueness: { scope: :page_id }
    validate :project_matches_page_organization

    private

    def project_matches_page_organization
      return if page.blank? || project.blank? || page.organization_id.blank?

      errors.add(:project, :invalid) if project.organization_id != page.organization_id
    end
  end
end
