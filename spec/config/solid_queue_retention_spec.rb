# frozen_string_literal: true

require "rails_helper"

# Ingest jobs carry whole payloads (metrics, logs, replays) in their arguments: kept for the default
# day after finishing they made the queue database grow by the day's traffic (CYRA-896).
RSpec.describe "Solid Queue finished-job retention" do
  let(:retention) { SolidQueue.clear_finished_jobs_after }

  it "keeps finished jobs for one hour" do
    expect(retention).to eq(1.hour)
  end

  it "stays longer than the stall window the throughput check reads" do
    expect(retention).to be > Ops::QueueThroughput::STALL_THRESHOLD
  end
end
