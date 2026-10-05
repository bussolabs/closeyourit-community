# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::Workload do
  let(:now) { Time.zone.parse("2026-10-02 09:00:00") }
  let(:minute) { ->(at) { at.to_i / 60 } }

  it "counts restarts inside a window" do
    workload = build(:cluster_workload, restart_marks: [ [ minute.(now - 12.minutes), 3 ], [ minute.(now - 4.minutes), 2 ] ])
    expect(workload.recent_restarts(10.minutes, now:)).to eq(2)
    expect(workload.restarts_24h(now:)).to eq(5)
  end

  it "is crashlooping at three restarts in thirty minutes" do
    workload = build(:cluster_workload, restart_marks: [ [ minute.(now - 2.minutes), 3 ] ])
    expect(workload.crashlooping?(now:)).to be(true)
  end

  # Kubernetes caps the back-off at five minutes: a steady crash loop restarts once every five
  # minutes and is caught between restarts with reason "Error", not "CrashLoopBackOff".
  it "stays crashlooping at the capped back-off of one restart every five minutes" do
    marks = (0..5).map { |i| [ minute.(now - (i * 5).minutes - 1.minute), 1 ] }
    workload = build(:cluster_workload, last_reason: "Error", restart_marks: marks)
    expect(workload.crashlooping?(now:)).to be(true)
  end

  it "is not crashlooping after two restarts in thirty minutes" do
    workload = build(:cluster_workload, last_reason: "Error", restart_marks: [ [ minute.(now - 20.minutes), 2 ] ])
    expect(workload.crashlooping?(now:)).to be(false)
  end

  it "is crashlooping while Kubernetes says CrashLoopBackOff" do
    expect(build(:cluster_workload, last_reason: "CrashLoopBackOff").crashlooping?(now:)).to be(true)
  end

  it "is degraded when fewer copies are ready than desired" do
    workload = build(:cluster_workload, desired: 3, ready: 1, degraded_since: now - 6.minutes)
    expect(workload.degraded?).to be(true)
    expect(workload.degraded_for?(5.minutes, now:)).to be(true)
    expect(build(:cluster_workload, desired: 2, ready: 2).degraded?).to be(false)
  end
end
