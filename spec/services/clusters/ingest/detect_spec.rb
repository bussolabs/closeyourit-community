# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::Ingest::Detect do
  include ActiveJob::TestHelper

  let(:now) { Time.zone.parse("2026-10-02 09:00:00") }
  let(:cluster) { create(:cluster) }

  def alerted(event_type)
    enqueued_jobs.select { |job| job["job_class"] == "Alerting::EvaluateJob" }
                 .map { |job| job["arguments"].first }
                 .select { |args| args["event_type"] == event_type }
  end

  it "announces a cluster coming back from down" do
    described_class.call(cluster:, now:, previous_status: "down")
    expect(alerted("cluster_up").size).to eq(1)
  end

  it "stays quiet for a cluster coming up for the first time" do
    described_class.call(cluster:, now:, previous_status: "pending")
    expect(alerted("cluster_up")).to be_empty
  end

  it "alerts once for a node not ready for two minutes and re-arms when it recovers" do
    node = create(:cluster_node, cluster:, ready: false, not_ready_since: now - 3.minutes)
    2.times { described_class.call(cluster:, now:, previous_status: "up") }
    expect(alerted("cluster_node_not_ready").size).to eq(1)

    node.update!(ready: true, not_ready_since: nil)
    described_class.call(cluster:, now:, previous_status: "up")
    expect(node.reload.not_ready_alerted_at).to be_nil
  end

  it "waits two minutes before calling a node not ready" do
    create(:cluster_node, cluster:, ready: false, not_ready_since: now - 1.minute)
    described_class.call(cluster:, now:, previous_status: "up")
    expect(alerted("cluster_node_not_ready")).to be_empty
  end

  it "ignores a node the autoscaler is removing" do
    create(:cluster_node, cluster:, ready: false, being_removed: true, not_ready_since: now - 1.hour)
    described_class.call(cluster:, now:, previous_status: "up")
    expect(alerted("cluster_node_not_ready")).to be_empty
  end

  it "alerts on node pressure once" do
    create(:cluster_node, cluster:, pressure: { "disk" => true })
    2.times { described_class.call(cluster:, now:, previous_status: "up") }
    expect(alerted("cluster_node_pressure").size).to eq(1)
  end

  it "alerts a degraded workload after five minutes, to its project when linked" do
    project = create(:project, organization: cluster.organization)
    namespace = create(:cluster_namespace, cluster:, project:)
    create(:cluster_workload, cluster:, namespace:, desired: 3, ready: 1, degraded_since: now - 6.minutes)

    described_class.call(cluster:, now:, previous_status: "up")

    expect(alerted("cluster_workload_degraded").sole["project_id"]).to eq(project.id)
  end

  it "alerts a crash loop once and re-arms after fifteen quiet minutes" do
    workload = create(:cluster_workload, cluster:, restart_marks: [ [ (now - 1.minute).to_i / 60, 6 ] ])
    2.times { described_class.call(cluster:, now:, previous_status: "up") }
    expect(alerted("cluster_workload_crashloop").size).to eq(1)

    described_class.call(cluster:, now: now + 16.minutes, previous_status: "up")
    expect(workload.reload.crashloop_alerted_at).to be_nil
  end

  it "alerts a crashing app once, as a crash loop, even when copies are missing" do
    create(:cluster_workload, cluster:, desired: 1, ready: 0, degraded_since: now - 10.minutes, last_reason: "CrashLoopBackOff")
    described_class.call(cluster:, now:, previous_status: "up")
    expect(alerted("cluster_workload_crashloop").size).to eq(1)
    expect(alerted("cluster_workload_degraded")).to be_empty
  end

  it "says nothing while the cluster is paused" do
    cluster.update!(status: :paused)
    create(:cluster_node, cluster:, ready: false, not_ready_since: now - 1.hour)
    described_class.call(cluster:, now:, previous_status: "paused")
    expect(enqueued_jobs).to be_empty
  end
end
