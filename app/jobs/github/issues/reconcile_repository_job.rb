# frozen_string_literal: true

module Github
  module Issues
    # The nightly check of one repository (Github::Issues::Reconcile). A refusal from GitHub (a missing
    # permission, a repository no longer visible) is logged: retrying gets the same answer. CYRA-1055
    class ReconcileRepositoryJob < ApplicationJob
      queue_as :batch

      limits_concurrency to: 1, key: ->(repository_id:) { "github:reconcile:#{repository_id}" }

      def perform(repository_id:)
        repository = Github::Repository.find_by(id: repository_id)
        return if repository.nil?

        Github::Issues::Reconcile.call(repository:)
      rescue Github::Client::Error => e
        raise if e.transient?

        Rails.logger.warn("[github.issues.reconcile] #{e.code} repository=#{repository_id}: #{e.message}")
      end
    end
  end
end
