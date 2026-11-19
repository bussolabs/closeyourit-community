# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::CheckStaleJob do
  include ActiveJob::TestHelper

  it "marks silent clusters down once and alerts" do
    silent = create(:cluster, status: :up, last_snapshot_at: 4.minutes.ago)
    fresh = create(:cluster, status: :up, last_snapshot_at: 30.seconds.ago)
    paused = create(:cluster, status: :paused, last_snapshot_at: 1.hour.ago)

    expect { described_class.perform_now }.to have_enqueued_job(Alerting::EvaluateJob).once
    expect(silent.reload).to be_status_down
    expect(fresh.reload).to be_status_up
    expect(paused.reload).to be_status_paused
    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "writes the delivery mark once the alert is queued" do
    silent = create(:cluster, status: :up, last_snapshot_at: 4.minutes.ago)

    described_class.perform_now

    expect(silent.reload.down_alerted_at).to be_present
  end

  # CYRA-1228 — a restart between the status change and the alert leaves down + no mark: the check
  # never looks at it again, the reconcile round delivers it once.
  it "leaves the alert to the reconcile round when the process dies before queueing it" do
    silent = create(:cluster, status: :up, last_snapshot_at: 4.minutes.ago)
    allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "restart")
    expect { described_class.perform_now }.to raise_error(StandardError, "restart")
    allow(Alerting::EvaluateJob).to receive(:perform_later).and_call_original

    expect(silent.reload).to be_status_down
    expect(silent.down_alerted_at).to be_nil
    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)

    travel(5.minutes) do
      expect { Alerting::ReconcileOutages.call }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "cluster_down", subject_id: silent.id)).once
      expect { Alerting::ReconcileOutages.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  it "does not clear the mark nor queue again when a concurrent check declared it first" do
    silent = create(:cluster, status: :up, last_snapshot_at: 4.minutes.ago)
    rival = Clusters::Cluster.find(silent.id)
    calls = 0
    # The check already loaded the row as up when the rival declares it first.
    allow(Alerting::AnnounceOutage).to receive(:declare).and_wrap_original do |original, **kwargs|
      calls += 1
      original.call(subject: rival) if calls == 1
      original.call(**kwargs)
    end

    expect { described_class.perform_now }.to have_enqueued_job(Alerting::EvaluateJob).once
    expect(silent.reload).to be_status_down
    expect(silent.down_alerted_at).to be_present
  end

  it "ignores a revoked cluster" do
    create(:cluster, status: :up, last_snapshot_at: 1.hour.ago, revoked_at: Time.current)
    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end
end
