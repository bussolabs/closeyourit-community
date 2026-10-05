# frozen_string_literal: true

module Member
  # Figures of the clusters on one page, in a fixed number of queries whatever the page size. "Things
  # to look at" reads the alert memory of nodes and workloads: the same rule that sends the alerts (CYAG-22).
  class ClusterSummary
    Row = Data.define(:nodes_ready, :nodes_total, :apps_ok, :apps_total, :attention)

    def initialize(clusters)
      @ids = clusters.map(&:id)
    end

    def for(cluster)
      Row.new(
        nodes_ready: nodes.fetch([ cluster.id, true ], 0),
        nodes_total: nodes.fetch([ cluster.id, true ], 0) + nodes.fetch([ cluster.id, false ], 0),
        apps_ok: apps_ok.fetch(cluster.id, 0),
        apps_total: apps_total.fetch(cluster.id, 0),
        attention: node_attention.fetch(cluster.id, 0) + workload_attention.fetch(cluster.id, 0)
      )
    end

    private

    def nodes = @nodes ||= Clusters::Node.present.where(cluster_id: @ids).group(:cluster_id, :ready).count

    def apps_total = @apps_total ||= workloads.group(:cluster_id).count

    def apps_ok = @apps_ok ||= workloads.where("ready >= desired").where(crashloop_alerted_at: nil).group(:cluster_id).count

    def node_attention
      @node_attention ||= Clusters::Node.present.where(cluster_id: @ids)
                                        .where.not(not_ready_alerted_at: nil)
                                        .or(Clusters::Node.present.where(cluster_id: @ids).where.not(pressure_alerted_at: nil))
                                        .group(:cluster_id).count
    end

    def workload_attention
      @workload_attention ||= workloads.where.not(degraded_alerted_at: nil)
                                       .or(workloads.where.not(crashloop_alerted_at: nil))
                                       .group(:cluster_id).count
    end

    def workloads = Clusters::Workload.present.where(cluster_id: @ids)
  end
end
