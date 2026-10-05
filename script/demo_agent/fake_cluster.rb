# frozen_string_literal: true

# Development only. Builds cluster-snapshot/v1 payloads (contracts/cluster-snapshot/v1, the same wire
# format as closeyourit-kube) for a small fake Kubernetes cluster, pushed by bin/demo-agent (CYAG-22).
module DemoAgent
  class FakeCluster
    NAME = "demo-k8s"
    GB = 1024**3

    NODES = [
      { name: "pool-a-1", cpu: 38, mem: 61 },
      { name: "pool-a-2", cpu: 44, mem: 58 },
      { name: "pool-b-1", cpu: 27, mem: 72 }
    ].freeze

    # [namespace, kind, name, desired, image]
    WORKLOADS = [
      [ "shop-production", "Deployment", "storefront-web", 3, "shop/storefront:2.14.0" ],
      [ "shop-production", "Deployment", "payments-worker", 2, "shop/payments:1.9.2" ],
      [ "shop-production", "Deployment", "search", 2, "shop/search:0.8.1" ],
      [ "shop-staging", "Deployment", "storefront-web", 1, "shop/storefront:2.15.0-rc.1" ],
      [ "kube-system", "Deployment", "coredns", 2, "coredns/coredns:1.11.3" ],
      [ "kube-system", "DaemonSet", "svclb-traefik", 3, "rancher/klipper-lb:v0.4.9" ]
    ].freeze

    # Faults come and go so alerts fire and clear while the agent runs: [every, lasts] in minutes.
    CRASHLOOP = [ "payments-worker", 20, 8 ].freeze
    DEGRADED = [ "search", 25, 9 ].freeze

    def initialize
      @restarts = Hash.new(0)
    end

    def payload(at: Time.current)
      @at = at
      {
        "snapshot_id" => SecureRandom.uuid, "observed_at" => at.utc.iso8601, "observer_version" => "0.1.0",
        "cluster" => { "kubernetes_version" => "v1.31.4", "provider" => "hcloud", "metrics_available" => true },
        "nodes" => NODES.map { |spec| node(**spec) },
        "namespaces" => WORKLOADS.map(&:first).uniq.map { |name| { "name" => name } },
        "workloads" => WORKLOADS.map { |spec| workload(*spec) },
        "events" => events,
        "truncated" => false
      }
    end

    private

    def node(name:, cpu:, mem:)
      cpu_capacity = 4000
      memory_capacity = 8 * GB
      {
        "name" => name, "ready" => true, "pressure" => { "memory" => false, "disk" => false, "pid" => false },
        "unschedulable" => false, "being_removed" => false,
        "cpu_capacity_millicores" => cpu_capacity, "memory_capacity_bytes" => memory_capacity,
        "cpu_usage_millicores" => (cpu_capacity * jitter(cpu, 12) / 100).round,
        "memory_usage_bytes" => (memory_capacity * jitter(mem, 4) / 100).round,
        "pods" => rand(8..14), "created_at" => 9.days.ago.utc.iso8601, "provider_id" => "hcloud://demo-#{name}"
      }
    end

    def workload(namespace, kind, name, desired, image)
      crashing = namespace == "shop-production" && name == CRASHLOOP.first && fault?(CRASHLOOP)
      degraded = namespace == "shop-production" && name == DEGRADED.first && fault?(DEGRADED)
      key = "#{namespace}/#{name}"
      @restarts[key] += 2 if crashing
      ready = crashing ? 0 : (degraded ? desired - 1 : desired)
      {
        "kind" => kind, "namespace" => namespace, "name" => name, "desired" => desired, "ready" => ready,
        "available" => ready, "image" => image, "restarts" => @restarts[key],
        "last_reason" => (crashing ? "CrashLoopBackOff" : (degraded ? "Unschedulable" : nil))
      }
    end

    def events
      return [] unless fault?(CRASHLOOP)

      [ { "reason" => "BackOff", "object_kind" => "Pod", "object_name" => "payments-worker-6c9d7-k2x8p",
          "namespace" => "shop-production", "message" => "Back-off restarting failed container payments-worker",
          "count" => @restarts["shop-production/payments-worker"], "last_seen_at" => @at.utc.iso8601 } ]
    end

    def fault?((_name, every, lasts)) = (@at.to_i / 60) % every < lasts

    def jitter(base, swing) = (base + rand(-swing.to_f..swing.to_f)).clamp(1, 99)
  end
end
