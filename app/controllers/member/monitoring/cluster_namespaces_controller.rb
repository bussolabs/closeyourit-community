# frozen_string_literal: true

module Member
  module Monitoring
    # Links a cluster namespace to a project environment, or unlinks it (CYAG-22). servers.manage; the
    # project must be one the viewer can see, or the answer is 404.
    class ClusterNamespacesController < Member::BaseController
      include Indexable

      before_action -> { require_permission!("servers.manage") }

      def update
        cluster = visible.clusters.find(params[:cluster_id])
        namespace = cluster.namespaces.find(params[:id])
        project_id, environment_id = params[:link].to_s.split(":", 2)
        if project_id.blank?
          ::Clusters::Namespaces::Unlink.call(namespace:)
          return redirect_to member_monitoring_cluster_path(cluster), notice: t("member.clusters.namespaces.unlinked_notice")
        end

        project = visible.projects.find(project_id)
        environment = environment_id.present? ? project.environments.find(environment_id) : nil
        result = ::Clusters::Namespaces::Link.call(namespace:, project:, environment:)
        flash_key = result.ok? ? { notice: t("member.clusters.namespaces.linked") } : { alert: result.error.message }
        redirect_to member_monitoring_cluster_path(cluster), **flash_key
      end
    end
  end
end
