# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::PruneJob do
  around { |example| travel_to(Time.zone.local(2026, 11, 20, 12)) { example.run } }

  [ 0, 1, 1001 ].each do |count|
    it "deletes #{count} expired rows per category in bounded batches" do
      cluster = create(:cluster)
      namespace = create(:cluster_namespace, cluster:)
      boundary = [
        create(:cluster_workload, cluster:, namespace:, gone_at: 24.hours.ago),
        create(:cluster_node, cluster:, gone_at: 24.hours.ago),
        create(:cluster_namespace, cluster:, gone_at: 24.hours.ago),
        Clusters::Event.create!(cluster:, reason: "BackOff", last_seen_at: 48.hours.ago)
      ]
      boundary.each do |record|
        column = record.is_a?(Clusters::Event) ? "last_seen_at" : "gone_at"
        rows = Array.new(count) do |index|
          attributes = record.attributes.except("id").merge(column => record[column] - 1.second)
          attributes["name"] = "expired-#{index}" if record.has_attribute?(:name)
          attributes
        end
        record.class.insert_all!(rows) if count.positive?
      end
      deleted = []
      allow(Clusters::Workload.connection).to receive(:delete).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { |rows| deleted << rows }
      end

      described_class.perform_now

      boundary.each { |record| expect(record.class).to exist(record.id) }
      expect(Clusters::Workload.count).to eq(1)
      expect(Clusters::Node.count).to eq(1)
      expect(Clusters::Namespace.count).to eq(2)
      expect(Clusters::Event.count).to eq(1)
      expect(deleted.sum).to eq(count * 4)
      expect(deleted).to all(be <= 1000)
      expect(deleted.count(&:positive?)).to eq((count / 1000.0).ceil * 4)

      described_class.perform_now

      expect(deleted.sum).to eq(count * 4)
      boundary.each { |record| expect(record.class).to exist(record.id) }
    end
  end

  it "keeps occupied namespaces and removes namespaces emptied in the same run" do
    cluster = create(:cluster)
    occupied = create(:cluster_namespace, cluster:, gone_at: 2.days.ago)
    emptied = create(:cluster_namespace, cluster:, gone_at: 2.days.ago)
    active = create(:cluster_workload, cluster:, namespace: occupied)
    boundary = create(:cluster_workload, cluster:, namespace: occupied, gone_at: 24.hours.ago)
    create(:cluster_workload, cluster:, namespace: emptied, gone_at: 25.hours.ago)
    present = create(:cluster_node, cluster:)

    2.times { described_class.perform_now }

    expect(Clusters::Namespace.pluck(:id)).to contain_exactly(occupied.id)
    expect(Clusters::Workload.pluck(:id)).to contain_exactly(active.id, boundary.id)
    expect(Clusters::Node).to exist(present.id)
  end

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
