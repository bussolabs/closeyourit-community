# frozen_string_literal: true

module Clusters
  # "What is wrong now" for a cluster, from the same model predicates the alerts use, so the page and
  # the alerts never disagree. A silent cluster says only that: its stored state is old (CYAG-22).
  module Health
    Problem = Data.define(:kind, :severity, :subject, :since)
    SEVERITY_ORDER = { danger: 0, warning: 1 }.freeze

    def self.problems(cluster, now: Time.current)
      return [ Problem.new(:cluster_down, :danger, cluster, cluster.last_snapshot_at) ] if cluster.status_down?

      list = workload_problems(cluster, now) + node_problems(cluster, now)
      list.each_with_index.sort_by { |problem, index| [ SEVERITY_ORDER.fetch(problem.severity), index ] }.map(&:first)
    end

    def self.workload_problems(cluster, now)
      cluster.workloads.present.includes(:namespace).flat_map do |workload|
        found = []
        # A crash loop also leaves copies missing: one problem per app, the most serious one.
        if workload.crashlooping?(now:)
          found << Problem.new(:workload_crashloop, :danger, workload, nil)
        elsif workload.degraded_for?(Clusters::Constants::WORKLOAD_DEGRADED_AFTER, now:)
          found << Problem.new(:workload_degraded, :warning, workload, workload.degraded_since)
        end
        found
      end
    end

    def self.node_problems(cluster, now)
      cluster.nodes.present.flat_map do |node|
        found = []
        if node.not_ready_for?(Clusters::Constants::NODE_NOT_READY_AFTER, now:)
          found << Problem.new(:node_not_ready, :warning, node, node.not_ready_since)
        end
        found << Problem.new(:node_pressure, :warning, node, nil) if node.pressured?
        found
      end
    end
  end
end
