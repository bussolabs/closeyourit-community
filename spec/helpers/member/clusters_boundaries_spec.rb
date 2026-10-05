# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::ClustersHelper, type: :helper do
  it "distinguishes draining, unavailable and pressured nodes" do
    node = build(:cluster_node, being_removed: true)
    expect(helper.cluster_node_badge(node)).to include(I18n.t("member.clusters.nodes.removing"))
    node.assign_attributes(being_removed: false, ready: false, not_ready_since: nil)
    expect(helper.cluster_node_badge(node)).to include("bg-red")
    node.assign_attributes(ready: true, pressure: { "memory" => true })
    expect(helper.cluster_node_badge(node)).to include(I18n.t("member.clusters.nodes.pressure"))
  end

  it "distinguishes unavailable workloads with and without a reported reason" do
    workload = build(:cluster_workload, ready: 0, desired: 1, last_reason: "ImagePullBackOff")
    expect(helper.cluster_workload_badge(workload)).to include("ImagePullBackOff")
    workload.assign_attributes(last_reason: nil, degraded_since: nil)
    expect(helper.cluster_workload_badge(workload)).to include("bg-amber")
    workload.assign_attributes(last_reason: "CrashLoopBackOff")
    expect(helper.cluster_workload_badge(workload)).to include(I18n.t("member.clusters.workloads.crashloop"))
  end

  it "keeps paused and pending cluster states distinct from down" do
    cluster = build(:cluster, status: :paused)
    expect(helper.send(:cluster_status, cluster, nil).last).to eq(:gray)
    cluster.status = :pending
    expect(helper.send(:cluster_status, cluster, nil).last).to eq(:sky)
    cluster.assign_attributes(status: :down, last_snapshot_at: nil, created_at: 1.minute.ago)
    expect(helper.send(:cluster_status, cluster, nil).last).to eq(:red)
  end
end
