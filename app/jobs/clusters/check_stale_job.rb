# frozen_string_literal: true

module Clusters
  # Every minute: an up cluster with no snapshot for STALE_AFTER_SECONDS goes down and alerts once.
  # Apply brings it back up at the next snapshot (CYAG-22).
  class CheckStaleJob < ApplicationJob
    queue_as :servers
    limits_concurrency to: 1, key: "periodic", duration: 5.minutes, on_conflict: :discard

    def perform
      Clusters::Cluster.stale.find_each do |cluster|
        # The mark is written only once the alert is queued (CYRA-1228): a restart in between leaves
        # down + no mark, and Alerting::ReconcileOutages delivers it. The status change re-reads the
        # row under lock: one already declared by a concurrent check is skipped.
        Alerting::AnnounceOutage.declare(subject: cluster)
      end
    end
  end
end
