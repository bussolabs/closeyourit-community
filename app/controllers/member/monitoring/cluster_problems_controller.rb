# frozen_string_literal: true

module Member
  module Monitoring
    # "What is wrong now" tab of a Kubernetes cluster (CYAG-22): servers.view, one row per problem.
    class ClusterProblemsController < Member::BaseController
      include Indexable

      before_action -> { require_permission!("servers.view") }

      def index
        @cluster = visible.clusters.find(params[:cluster_id])
        @problems = ::Clusters::Health.problems(@cluster)
      end
    end
  end
end
