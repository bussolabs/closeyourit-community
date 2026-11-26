# frozen_string_literal: true

module Github
  module Issues
    # The nightly round (config/recurring.yml): one job per repository whose issues are synced, so one
    # repository that GitHub refuses does not stop the others. CYRA-1055
    class ReconcileJob < ApplicationJob
      queue_as :batch

      def perform
        Github::Repository.where(sync_enabled: true).where.not(issue_sync: :off).ids.each do |repository_id|
          Github::Issues::ReconcileRepositoryJob.perform_later(repository_id:)
        end
      end
    end
  end
end
