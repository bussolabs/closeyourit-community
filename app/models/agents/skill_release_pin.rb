# frozen_string_literal: true

module Agents
  # The skills version an organization chose to stay on (CYRA-912). Optional: without it the
  # organization follows the latest available version.
  class SkillReleasePin < ApplicationRecord
    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :skill_release_pin
    belongs_to :skill_release, class_name: "Agents::SkillRelease", inverse_of: :pins

    validates :organization_id, uniqueness: true
  end
end
