# frozen_string_literal: true

module Clusters
  # Every minute: an up cluster with no snapshot for STALE_AFTER_SECONDS goes down and alerts once.
  # Apply brings it back up at the next snapshot (CYAG-22).
  class CheckStaleJob < ApplicationJob
    queue_as :servers

    def perform
      Clusters::Cluster.stale.find_each do |cluster|
        cluster.update!(status: :down)
        Clusters::Alerts.notify(:cluster_down, subject: cluster, cluster:)
      end
    end
  end
end
