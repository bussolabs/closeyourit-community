# frozen_string_literal: true

module Connections
  # Join progetto ↔ piattaforma: dichiara su quali piattaforme gira un progetto.
  # Integrità tenant: la piattaforma deve appartenere alla stessa org del progetto.
  class ProjectPlatform < ApplicationRecord
    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :project_platforms
    belongs_to :platform,
               class_name: "Types::Platform",
               inverse_of: :project_platforms

    validates :platform_id, uniqueness: { scope: :project_id }
    validate :platform_matches_project_organization

    # Link verso una piattaforma uptime-capable (per la scope Projects::Project.uptime_capable).
    scope :uptime_capable, -> { joins(:platform).where(types_platforms: { supports_uptime: true }) }

    # Link verso una piattaforma analytics-capable (per la scope Projects::Project.analytics_capable).
    scope :analytics_capable, -> { joins(:platform).where(types_platforms: { supports_analytics: true }) }

    # Link verso una piattaforma session-replay-capable (per Projects::Project.session_replay_capable).
    scope :session_replay_capable, -> { joins(:platform).where(types_platforms: { supports_session_replay: true }) }

    private

    def platform_matches_project_organization
      return if project.blank? || platform.blank?

      errors.add(:platform, :invalid) if platform.organization_id != project.organization_id
    end
  end
end
