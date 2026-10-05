# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::Ingest::Apply do
  let(:cluster) { create(:cluster, status: :pending) }
  let(:fixture) { JSON.parse(Rails.root.join("contracts/cluster-snapshot/v1/fixtures/valid/complete.json").read) }
  let(:now) { Time.zone.parse("2026-10-02 09:01:30") }

  before { allow(Clusters::Ingest::Detect).to receive(:call) }

  it "stores cluster facts, nodes, namespaces, workloads and events" do
    described_class.call(cluster:, payload: fixture, now:)

    cluster.reload
    expect(cluster).to be_status_up
    expect(cluster).to have_attributes(kubernetes_version: "v1.31.4", provider: "hcloud", metrics_available: true)
    expect(cluster.nodes.pluck(:name)).to contain_exactly("pool-a-1c9", "pool-b-7f2")
    expect(cluster.nodes.find_by(name: "pool-b-7f2")).to have_attributes(ready: false, being_removed: true, not_ready_since: now)
    checkout = cluster.workloads.find_by(name: "checkout")
    expect(checkout).to have_attributes(kind: "Deployment", desired: 3, ready: 1, last_reason: "OOMKilled",
                                        restarts_total: 34, degraded_since: now)
    expect(checkout.namespace.name).to eq("shop-production")
    expect(cluster.events.count).to eq(1)
    expect(Clusters::Ingest::Detect).to have_received(:call).with(cluster:, now:, previous_status: "pending")
  end

  it "marks what disappeared as gone and brings it back when it returns" do
    described_class.call(cluster:, payload: fixture, now:)
    without = fixture.merge("nodes" => fixture["nodes"].first(1), "workloads" => [])
    described_class.call(cluster:, payload: without, now: now + 1.minute)

    expect(cluster.nodes.find_by(name: "pool-b-7f2").gone_at).to eq(now + 1.minute)
    expect(cluster.workloads.present).to be_empty

    described_class.call(cluster:, payload: fixture, now: now + 2.minutes)
    expect(cluster.nodes.find_by(name: "pool-b-7f2").gone_at).to be_nil
  end

  it "records restarts as positive deltas, also after pods are recreated" do
    described_class.call(cluster:, payload: fixture, now:)
    workload = cluster.workloads.find_by(name: "checkout")
    expect(workload.restart_marks).to eq([])

    bump = ->(total) { fixture.deep_dup.tap { |payload| payload["workloads"][0]["restarts"] = total } }
    described_class.call(cluster:, payload: bump.(40), now: now + 1.minute)
    described_class.call(cluster:, payload: bump.(2), now: now + 2.minutes)

    expect(workload.reload.restart_marks.map(&:last)).to eq([ 6, 2 ])
  end

  it "keeps a node not-ready start time across snapshots" do
    described_class.call(cluster:, payload: fixture, now:)
    described_class.call(cluster:, payload: fixture, now: now + 1.minute)
    expect(cluster.nodes.find_by(name: "pool-b-7f2").not_ready_since).to eq(now)
  end

  it "does not insert the same event twice" do
    2.times { |i| described_class.call(cluster:, payload: fixture, now: now + i.minutes) }
    expect(cluster.events.count).to eq(1)
  end

  it "refreshes the open cluster pages after the snapshot" do
    allow(Clusters::Broadcast).to receive(:refresh)
    described_class.call(cluster:, payload: fixture, now:)
    expect(Clusters::Broadcast).to have_received(:refresh).with(cluster)
  end

  it "keeps a paused cluster paused" do
    cluster.update!(status: :paused)
    described_class.call(cluster:, payload: fixture, now:)
    expect(cluster.reload).to be_status_paused
  end

  it "caps the lists even if the observer sent more" do
    nodes = Array.new(Clusters::Constants::MAX_NODES + 5) { |i| fixture["nodes"][0].merge("name" => "n#{i}") }
    described_class.call(cluster:, payload: fixture.merge("nodes" => nodes), now:)
    expect(cluster.nodes.count).to eq(Clusters::Constants::MAX_NODES)
  end
end
