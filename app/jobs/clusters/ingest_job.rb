# frozen_string_literal: true

module Clusters
  # Applies one snapshot. A cluster deleted or revoked meanwhile makes it a no-op (CYAG-22).
  class IngestJob < ApplicationJob
    queue_as :servers_ingest

    def perform(cluster_id:, payload:)
      cluster = Clusters::Cluster.find_by(id: cluster_id)
      return if cluster.nil? || cluster.revoked?

      Clusters::Ingest::Apply.call(cluster:, payload:)
    end
  end
end
