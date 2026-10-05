# frozen_string_literal: true

module Member
  module Monitoring
    # Apps tab of a Kubernetes cluster (CYAG-22): servers.view, sortable, paginated, filter by namespace.
    class ClusterWorkloadsController < Member::BaseController
      include Indexable

      SORT_COLUMNS = {
        "name" => "LOWER(clusters_workloads.name)",
        "namespace" => "LOWER(clusters_namespaces.name)",
        "copies" => "clusters_workloads.ready - clusters_workloads.desired",
        "reason" => :last_reason
      }.freeze

      before_action -> { require_permission!("servers.view") }

      remembers_filters :namespace, :q, :sort, only: :index

      def index
        @cluster = visible.clusters.find(params[:cluster_id])
        @problems = ::Clusters::Health.problems(@cluster)
        @namespaces = @cluster.namespaces.present.order(:name)
        scope = @cluster.workloads.present.joins(:namespace).includes(namespace: %i[project environment]).order(:name)
        scope = scope.where(clusters_namespaces: { name: filter_ids(:namespace) }) if filter_ids(:namespace).any?
        @workloads = paginated(filter_by_search(scope, "clusters_workloads.name", "clusters_workloads.image"), columns: SORT_COLUMNS)
      end
    end
  end
end
