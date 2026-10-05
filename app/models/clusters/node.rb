# frozen_string_literal: true

module Clusters
  # Current state of one Kubernetes node, upserted by name at every snapshot (CYAG-22).
  class Node < ApplicationRecord
    belongs_to :cluster, class_name: "Clusters::Cluster", inverse_of: :nodes

    scope :present, -> { where(gone_at: nil) }

    # A node the cluster autoscaler is draining on purpose is never "not ready" for alerts.
    def not_ready_for?(duration, now: Time.current)
      !ready && !being_removed && not_ready_since.present? && not_ready_since <= now - duration
    end

    def pressured? = pressure.to_h.values.any?(true)
  end
end
