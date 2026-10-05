# frozen_string_literal: true

require "rails_helper"

# Cluster alerts (CYAG-22): organization branch for the cluster and its machines, project branch
# for a workload whose namespace is linked to a project.
RSpec.describe Alerting::Evaluate do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:cluster) { create(:cluster, organization:) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  it "delivers cluster_down at organization level, linking the cluster" do
    create(:alerting_rule, organization:, event_type: :cluster_down, name: "Silent")

    result = described_class.call(event_type: "cluster_down", subject_type: "Clusters::Cluster", subject_id: cluster.id,
                                  project_id: nil, organization_id: organization.id)

    expect(result.value).to be > 0
    notification = Alerting::Notification.find_by(account: owner, event_type: "cluster_down")
    expect(notification.subject).to eq(cluster)
    expect(notification.project).to be_nil
    expect(notification.url).to eq("/member/monitoring/clusters/#{cluster.id}")
  end

  it "delivers a workload alert of a linked namespace as a project alert" do
    project = create(:project, organization:)
    namespace = create(:cluster_namespace, cluster:, project:)
    workload = create(:cluster_workload, cluster:, namespace:, desired: 3, ready: 1)
    create(:alerting_rule, organization:, event_type: :cluster_workload_degraded, name: "Half")

    result = described_class.call(event_type: "cluster_workload_degraded", subject_type: "Clusters::Workload",
                                  subject_id: workload.id, project_id: project.id, organization_id: organization.id)

    expect(result.value).to be > 0
    notification = Alerting::Notification.find_by(account: owner, event_type: "cluster_workload_degraded")
    expect(notification.subject).to eq(workload)
    expect(notification.title).to include(workload.name)
  end
end
