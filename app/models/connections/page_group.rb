# frozen_string_literal: true

module Connections
  # Join N:N pagina KB ↔ gruppo di progetti (gemello di Connections::BookGroup). La pagina vale per
  # tutti i progetti del gruppo, anche quelli aggiunti in seguito. Tenant via page.organization_id.
  class PageGroup < ApplicationRecord
    belongs_to :page,
               class_name: "Knowledge::Page",
               inverse_of: :page_groups
    belongs_to :group,
               class_name: "Projects::Group",
               inverse_of: :page_groups

    validates :group_id, uniqueness: { scope: :page_id }
    validate :group_matches_page_organization

    private

    def group_matches_page_organization
      return if page.blank? || group.blank? || page.organization_id.blank?

      errors.add(:group, :invalid) if group.organization_id != page.organization_id
    end
  end
end
