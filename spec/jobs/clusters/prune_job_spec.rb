# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::PruneJob do
  it "deletes what has been gone for a day and events older than two days" do
    cluster = create(:cluster)
    old_node = create(:cluster_node, cluster:, gone_at: 25.hours.ago)
    recent_node = create(:cluster_node, cluster:, gone_at: 1.hour.ago)
    old_workload = create(:cluster_workload, cluster:, gone_at: 25.hours.ago)
    Clusters::Event.create!(cluster:, reason: "BackOff", last_seen_at: 49.hours.ago)
    Clusters::Event.create!(cluster:, reason: "BackOff", last_seen_at: 1.hour.ago)

    described_class.perform_now

    expect(Clusters::Node.exists?(old_node.id)).to be(false)
    expect(Clusters::Node.exists?(recent_node.id)).to be(true)
    expect(Clusters::Workload.exists?(old_workload.id)).to be(false)
    expect(cluster.events.count).to eq(1)
  end

  it "keeps a gone namespace that is linked to a project" do
    cluster = create(:cluster)
    linked = create(:cluster_namespace, cluster:, project: create(:project, organization: cluster.organization), gone_at: 2.days.ago)
    unlinked = create(:cluster_namespace, cluster:, gone_at: 2.days.ago)

    described_class.perform_now

    expect(Clusters::Namespace.exists?(linked.id)).to be(true)
    expect(Clusters::Namespace.exists?(unlinked.id)).to be(false)
  end
end
