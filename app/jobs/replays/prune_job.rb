# frozen_string_literal: true

module Replays
  # Pota le sessioni di replay oltre la retention del progetto (pref `replay_retention_days`,
  # altrimenti REPLAY_RETENTION_DEFAULT_DAYS). Usa `destroy` (NON delete_all) per PURGARE anche gli
  # attachment su S3: un replay è PII pesante, i byte devono sparire davvero. Daily (recurring.yml).
  class PruneJob < ApplicationJob
    queue_as :batch

    def perform
      Projects::Project.find_each do |project|
        cutoff = retention_days(project).days.ago
        project.replay_sessions.where(created_at: ..cutoff).find_each(&:destroy)
      end
    end

    private

    def retention_days(project)
      (project.replay_retention_days.presence || Replays::Constants::RETENTION_DEFAULT_DAYS).to_i
    end
  end
end
