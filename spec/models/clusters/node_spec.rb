# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::Node do
  let(:now) { Time.zone.parse("2026-10-02 09:00:00") }

  it "is not ready for a duration only once the not-ready time has passed" do
    node = build(:cluster_node, ready: false, not_ready_since: now - 3.minutes)
    expect(node.not_ready_for?(2.minutes, now:)).to be(true)
    expect(node.not_ready_for?(5.minutes, now:)).to be(false)
  end

  it "never counts a node the autoscaler is removing" do
    node = build(:cluster_node, ready: false, being_removed: true, not_ready_since: now - 1.hour)
    expect(node.not_ready_for?(2.minutes, now:)).to be(false)
  end

  it "is pressured when any pressure flag is on" do
    expect(build(:cluster_node, pressure: { "memory" => true }).pressured?).to be(true)
    expect(build(:cluster_node, pressure: { "memory" => false, "disk" => false }).pressured?).to be(false)
  end
end
