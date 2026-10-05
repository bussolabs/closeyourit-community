# frozen_string_literal: true

# Authentication of the closeyourit-kube observer: the bearer is the per-cluster cyi_k_ token and the
# token is the cluster identity. A revoked token answers its own code (CYAG-22).
module ClusterAuthentication
  extend ActiveSupport::Concern
  include OrganizationSuspension

  private

  def authenticate_cluster!
    cluster = Clusters::Cluster.find_by(token_digest: Digest::SHA256.hexdigest(presented_cluster_token))
    return render_error("R401-CLUSTER-001", "Unknown cluster token", status: :unauthorized) if cluster.nil?
    return render_error("R401-CLUSTER-002", "Revoked cluster token", status: :unauthorized) if cluster.revoked?

    Current.organization = cluster.organization
    Current.cluster = cluster
    reject_suspended_organization!
  end

  def presented_cluster_token
    header = request.authorization
    return "" unless header&.start_with?("Bearer ")

    header.delete_prefix("Bearer ").strip
  end
end
