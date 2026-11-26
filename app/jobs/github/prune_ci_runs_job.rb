# frozen_string_literal: true

module Github
  # Nightly pruning of CI job outcomes older than CiJobRun::RETENTION (CYRA-1164), in batches like
  # Projects::PruneTestRunsJob. A job left with no runs goes too, unless a ticket was opened from it.
  class PruneCiRunsJob < ApplicationJob
    queue_as :batch

    BATCH = 500

    def perform(now = Time.current)
      Github::CiJobRun.where(completed_at: ...(now - Github::CiJobRun::RETENTION)).in_batches(of: BATCH).delete_all
      Github::CiJob.where(ticket_id: nil).where.missing(:runs).in_batches(of: BATCH).delete_all
    end
  end
end
