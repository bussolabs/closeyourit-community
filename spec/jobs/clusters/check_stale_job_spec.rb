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

  it "ignores a revoked cluster" do
    create(:cluster, status: :up, last_snapshot_at: 1.hour.ago, revoked_at: Time.current)
    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end
end
