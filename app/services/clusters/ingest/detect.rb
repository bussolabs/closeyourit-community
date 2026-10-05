# frozen_string_literal: true

module Clusters
  module Ingest
    # Turns the stored state into alerts. Each alert fires once per episode: the *_alerted_at column
    # is the memory, cleared when the episode ends (CYAG-22).
    class Detect < ApplicationService
      def initialize(cluster:, now:, previous_status:)
        @cluster = cluster
        @now = now
        @previous_status = previous_status.to_s
      end

      def call
        return Result.ok(0) if @cluster.status_paused?

        Clusters::Alerts.notify(:cluster_up, subject: @cluster, cluster: @cluster) if @previous_status == "down"
        @cluster.nodes.present.find_each { |node| detect_node(node) }
        @cluster.workloads.present.includes(:namespace).find_each { |workload| detect_workload(workload) }
        Result.ok(1)
      end

      private

      def detect_node(node)
        if node.not_ready_for?(Clusters::Constants::NODE_NOT_READY_AFTER, now: @now)
          fire(node, :not_ready_alerted_at, :cluster_node_not_ready)
        elsif node.ready && node.not_ready_alerted_at
          node.update_columns(not_ready_alerted_at: nil)
        end

        if node.pressured?
          fire(node, :pressure_alerted_at, :cluster_node_pressure)
        elsif node.pressure_alerted_at
          node.update_columns(pressure_alerted_at: nil)
        end
      end

      def detect_workload(workload)
        namespace = workload.namespace
        # A crash loop also leaves copies missing: it alerts as a crash loop only, never twice.
        if workload.degraded_for?(Clusters::Constants::WORKLOAD_DEGRADED_AFTER, now: @now) && !workload.crashlooping?(now: @now)
          fire(workload, :degraded_alerted_at, :cluster_workload_degraded, namespace:)
        elsif !workload.degraded? && workload.degraded_alerted_at
          workload.update_columns(degraded_alerted_at: nil)
        end

        if workload.crashlooping?(now: @now)
          fire(workload, :crashloop_alerted_at, :cluster_workload_crashloop, namespace:)
        elsif workload.crashloop_alerted_at && quiet?(workload)
          workload.update_columns(crashloop_alerted_at: nil)
        end
      end

      def quiet?(workload) = workload.recent_restarts(Clusters::Constants::CRASHLOOP_QUIET, now: @now).zero?

      def fire(record, memory, event_type, namespace: nil)
        return if record.public_send(memory)

        record.update_columns(memory => @now)
        Clusters::Alerts.notify(event_type, subject: record, cluster: @cluster, namespace:)
      end
    end
  end
end
