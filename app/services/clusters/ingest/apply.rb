# frozen_string_literal: true

module Clusters
  module Ingest
    # Writes one cluster-snapshot/v1 into the current state: upsert by name, gone_at for what is
    # missing, restart deltas into restart_marks, then Detect decides the alerts (CYAG-22).
    class Apply < ApplicationService
      def initialize(cluster:, payload:, now: Time.current)
        @cluster = cluster
        @payload = payload
        @now = now
      end

      def call
        previous_status = @cluster.status
        ActiveRecord::Base.transaction do
          apply_cluster
          apply_nodes
          apply_workloads(apply_namespaces)
          apply_events
        end
        Clusters::Ingest::Detect.call(cluster: @cluster, now: @now, previous_status:)
        Clusters::Broadcast.refresh(@cluster)
        Result.ok(@cluster)
      end

      private

      def list(key, cap) = Array(@payload[key]).grep(Hash).first(cap)

      def apply_cluster
        facts = @payload["cluster"].is_a?(Hash) ? @payload["cluster"] : {}
        attributes = {
          kubernetes_version: facts["kubernetes_version"].to_s.first(64),
          provider: facts["provider"].to_s.first(64),
          metrics_available: facts["metrics_available"] == true,
          observer_version: @payload["observer_version"].to_s.first(32),
          truncated: @payload["truncated"] == true
        }
        attributes[:status] = :up unless @cluster.status_paused?
        @cluster.update!(attributes)
      end

      def apply_nodes
        incoming = list("nodes", Clusters::Constants::MAX_NODES).index_by { |node| node["name"].to_s }
        existing = @cluster.nodes.reload.index_by(&:name)
        incoming.each { |name, data| save_node(existing[name] || @cluster.nodes.build(name:), data) }
        @cluster.nodes.present.where.not(name: incoming.keys).update_all(gone_at: @now, updated_at: @now)
      end

      def save_node(node, data)
        ready = data["ready"] == true
        node.assign_attributes(
          ready:, pressure: data["pressure"].is_a?(Hash) ? data["pressure"].slice("memory", "disk", "pid") : {},
          unschedulable: data["unschedulable"] == true, being_removed: data["being_removed"] == true,
          cpu_capacity_millicores: data["cpu_capacity_millicores"], memory_capacity_bytes: data["memory_capacity_bytes"],
          cpu_usage_millicores: data["cpu_usage_millicores"], memory_usage_bytes: data["memory_usage_bytes"],
          pods: data["pods"].to_i, node_created_at: parse_time(data["created_at"]),
          provider_id: data["provider_id"].to_s.first(512), gone_at: nil
        )
        node.not_ready_since = ready ? nil : (node.not_ready_since || @now)
        node.save!
      end

      # Namespaces come from the namespace list and from the workloads, so a workload never points
      # to a namespace the cap cut away.
      def apply_namespaces
        names = list("namespaces", Clusters::Constants::MAX_NAMESPACES).map { |ns| ns["name"].to_s }
        names |= list("workloads", Clusters::Constants::MAX_WORKLOADS).map { |workload| workload["namespace"].to_s }
        names.reject!(&:blank?)
        existing = @cluster.namespaces.reload.index_by(&:name)
        names.each do |name|
          namespace = existing[name] ||= @cluster.namespaces.build(name:)
          namespace.gone_at = nil
          namespace.save! if namespace.changed?
        end
        @cluster.namespaces.present.where.not(name: names).update_all(gone_at: @now, updated_at: @now)
        existing
      end

      def apply_workloads(namespaces)
        existing = @cluster.workloads.reload.index_by { |workload| [ workload.namespace_id, workload.kind, workload.name ] }
        seen = list("workloads", Clusters::Constants::MAX_WORKLOADS).filter_map do |data|
          namespace = namespaces[data["namespace"].to_s]
          kind = data["kind"].to_s
          next if namespace.nil? || Clusters::Workload::KINDS.exclude?(kind)

          key = [ namespace.id, kind, data["name"].to_s ]
          save_workload(existing[key] || @cluster.workloads.build(namespace:, kind:, name: key.last), data).id
        end
        @cluster.workloads.present.where.not(id: seen).update_all(gone_at: @now, updated_at: @now)
      end

      def save_workload(workload, data)
        record_restarts(workload, data["restarts"].to_i)
        workload.assign_attributes(
          desired: data["desired"].to_i, ready: data["ready"].to_i, available: data["available"].to_i,
          image: data["image"].to_s.first(512), last_reason: data["last_reason"].presence&.first(128), gone_at: nil
        )
        workload.degraded_since = workload.degraded? ? (workload.degraded_since || @now) : nil
        workload.save!
        workload
      end

      # The observer sends the sum of restartCount of the current pods: it drops when pods are
      # recreated, so a lower total counts as restarts since the recreation.
      def record_restarts(workload, total)
        if workload.persisted?
          delta = total >= workload.restarts_total ? total - workload.restarts_total : total
          horizon = (@now - Clusters::Constants::RESTART_MARKS_RETENTION).to_i / 60
          marks = workload.restart_marks.select { |minute, _| minute > horizon }
          marks << [ @now.to_i / 60, delta ] if delta.positive?
          workload.restart_marks = marks
        end
        workload.restarts_total = total
      end

      def apply_events
        rows = list("events", Clusters::Constants::MAX_EVENTS).filter_map { |data| event_row(data) }
        Clusters::Event.insert_all(rows, unique_by: :index_clusters_events_identity) if rows.any?
      end

      def event_row(data)
        seen_at = parse_time(data["last_seen_at"])
        return if seen_at.nil?

        {
          cluster_id: @cluster.id, namespace_name: data["namespace"].to_s.first(63), reason: data["reason"].to_s.first(128),
          object_kind: data["object_kind"].to_s.first(64), object_name: data["object_name"].to_s.first(253),
          message: data["message"].to_s.first(512), count: data["count"].to_i, last_seen_at: seen_at,
          created_at: @now, updated_at: @now
        }
      end

      def parse_time(value)
        Time.zone.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
