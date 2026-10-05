# frozen_string_literal: true

module Clusters
  # Thresholds and caps of the Kubernetes cluster domain. The caps mirror the cluster-snapshot/v1
  # contract: changing one means changing the contract and the observer too (CYAG-22).
  module Constants
    TOKEN_PREFIX = "cyi_k_"
    MAX_PAYLOAD_BYTES = 1.megabyte
    MAX_NODES = 500
    MAX_WORKLOADS = 3000
    MAX_NAMESPACES = 3000
    MAX_EVENTS = 200

    STALE_AFTER_SECONDS = 180
    NODE_NOT_READY_AFTER = 2.minutes
    WORKLOAD_DEGRADED_AFTER = 5.minutes
    CRASHLOOP_RESTARTS = 3
    CRASHLOOP_WINDOW = 30.minutes # Kubernetes caps back-off at 5 min: a steady loop restarts 6 times in 30
    CRASHLOOP_QUIET = 15.minutes
    RESTART_MARKS_RETENTION = 24.hours
    GONE_RETENTION = 24.hours
    EVENT_RETENTION = 48.hours
  end
end
