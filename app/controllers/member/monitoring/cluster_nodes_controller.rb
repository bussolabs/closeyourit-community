# frozen_string_literal: true

module Member
  module Monitoring
    # Machines tab of a Kubernetes cluster (CYAG-22): servers.view, sortable and paginated.
    class ClusterNodesController < Member::BaseController
      include Indexable

      SORT_COLUMNS = {
        "name" => "LOWER(clusters_nodes.name)",
        "status" => :ready,
        "cpu" => "clusters_nodes.cpu_usage_millicores * 1.0 / NULLIF(clusters_nodes.cpu_capacity_millicores, 0)",
        "memory" => "clusters_nodes.memory_usage_bytes * 1.0 / NULLIF(clusters_nodes.memory_capacity_bytes, 0)",
        "pods" => :pods,
        "age" => :node_created_at
      }.freeze

      before_action -> { require_permission!("servers.view") }

      remembers_filters :q, :sort, only: :index

      def index
        @cluster = visible.clusters.find(params[:cluster_id])
        @problems = ::Clusters::Health.problems(@cluster)
        scope = filter_by_search(@cluster.nodes.present.order(:name), "clusters_nodes.name")
        @nodes = paginated(scope, columns: SORT_COLUMNS)
      end
    end
  end
end
