# frozen_string_literal: true

module Connections
  class BookGroup < ApplicationRecord
    belongs_to :book,
               class_name: "Knowledge::Book",
               inverse_of: :book_groups
    belongs_to :group,
               class_name: "Projects::Group",
               inverse_of: :book_groups

    validates :group_id, uniqueness: { scope: :book_id }
    validate :group_matches_book_organization

    private

    def group_matches_book_organization
      return if book.blank? || group.blank? || book.organization_id.blank?

      errors.add(:group, :invalid) if group.organization_id != book.organization_id
    end
  end
end
