# frozen_string_literal: true

# Presentazione delle landing di area (CYRA-452, estesa all'osservabilità con CYRA-386).
module SpacesHelper
  # The Administration pages in three groups, by menu entry. An entry not listed here (a page added
  # later) lands in the last group rather than disappearing from the landing.
  SETTINGS_SECTIONS = {
    "people" => %w[member-nav-members member-nav-service-accounts member-nav-teams member-nav-roles],
    "projects" => %w[member-nav-platforms member-nav-environments],
    "organization" => []
  }.freeze

  def settings_sections(items)
    grouped = items.group_by do |item|
      SETTINGS_SECTIONS.find { |_key, tests| tests.include?(item.test) }&.first || SETTINGS_SECTIONS.keys.last
    end
    SETTINGS_SECTIONS.keys.filter_map { |key| [ key, grouped[key] ] if grouped[key] }
  end
end
