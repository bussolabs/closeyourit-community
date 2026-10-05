# frozen_string_literal: true

module Connections
  class BookProject < ApplicationRecord
    belongs_to :book,
               class_name: "Knowledge::Book",
               inverse_of: :book_projects
    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :book_projects

    validates :project_id, uniqueness: { scope: :book_id }
    validate :project_matches_book_organization

    private

    def project_matches_book_organization
      return if book.blank? || project.blank? || book.organization_id.blank?

      errors.add(:project, :invalid) if project.organization_id != book.organization_id
    end
  end
end
