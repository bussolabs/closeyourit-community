# frozen_string_literal: true

module Clusters
  # Hourly: forgets nodes and workloads gone for a day, unlinked namespaces gone for a day and
  # events older than two days. A linked namespace stays: its project link is a person's choice (CYAG-22).
  class PruneJob < ApplicationJob
    queue_as :batch

    def perform(now: Time.current)
      gone = now - Clusters::Constants::GONE_RETENTION
      Clusters::Workload.where(gone_at: ...gone).delete_all
      Clusters::Node.where(gone_at: ...gone).delete_all
      Clusters::Namespace.where(gone_at: ...gone, project_id: nil).where.missing(:workloads).delete_all
      Clusters::Event.where(last_seen_at: ...(now - Clusters::Constants::EVENT_RETENTION)).delete_all
    end
  end
end
