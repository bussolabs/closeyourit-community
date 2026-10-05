# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::Health do
  let(:now) { Time.zone.parse("2026-10-02 09:00:00") }

  it "lists what is wrong now, dangers first" do
    cluster = create(:cluster)
    create(:cluster_node, cluster:, ready: false, not_ready_since: now - 3.minutes)
    create(:cluster_workload, cluster:, last_reason: "CrashLoopBackOff")
    create(:cluster_workload, cluster:, desired: 2, ready: 2)

    problems = described_class.problems(cluster, now:)

    expect(problems.map(&:kind)).to eq(%i[workload_crashloop node_not_ready])
    expect(problems.first.severity).to eq(:danger)
  end

  it "reports a silent cluster and nothing else" do
    cluster = create(:cluster, status: :down)
    create(:cluster_workload, cluster:, last_reason: "CrashLoopBackOff")
    expect(described_class.problems(cluster, now:).map(&:kind)).to eq(%i[cluster_down])
  end

  it "names a crashing app once, as a crash loop" do
    cluster = create(:cluster)
    create(:cluster_workload, cluster:, desired: 1, ready: 0, degraded_since: now - 10.minutes, last_reason: "CrashLoopBackOff")
    expect(described_class.problems(cluster, now:).map(&:kind)).to eq(%i[workload_crashloop])
  end

  it "has nothing to say about a healthy cluster" do
    expect(described_class.problems(create(:cluster), now:)).to be_empty
  end
end
