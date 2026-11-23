# frozen_string_literal: true

require "rails_helper"

# Ingest jobs carry whole payloads (metrics, logs, replays) in their arguments: kept for the default
# day after finishing they made the queue database grow by the day's traffic (CYRA-896).
RSpec.describe "Solid Queue finished-job retention" do
  let(:retention) { SolidQueue.clear_finished_jobs_after }

  it "keeps finished jobs for one hour" do
    expect(retention).to eq(1.hour)
  end

  it "stays longer than the stall window the throughput check reads on the fast lanes" do
    expect(retention).to be > Ops::QueueThroughput::STALL_THRESHOLD
  end

  # The long lanes (CYRA-1229) wait longer than one hour, so past the hour a long lane «remembers»
  # nothing finished even when it is healthy. That is harmless only because a lane is stalled when
  # its oldest ready job ALSO waits past the threshold: no finished job on record is never enough.
  describe "on the lanes whose threshold outlasts the retention" do
    let(:now) { Time.current }
    let(:long_lane) { %w[batch ai] }

    it "is shorter than their thresholds, which is why the rule needs waiting work too" do
      expect(retention).to be < Ops::QueueThroughput::LONG_JOBS_STALL_THRESHOLD
      expect(retention).to be < Ops::QueueThroughput::SEO_STALL_THRESHOLD
    end

    it "does not call a long lane stalled just because its finished jobs were pruned" do
      stalled = Ops::QueueThroughput.stalled_lanes(now:, lanes: [ long_lane ],
                                                   oldest_ready_at: { "ai" => now - 40.minutes },
                                                   last_finished_at: {})

      expect(stalled).to be_empty
    end

    it "still calls it stalled once its work waits past the threshold" do
      stalled = Ops::QueueThroughput.stalled_lanes(now:, lanes: [ long_lane ],
                                                   oldest_ready_at: { "ai" => now - 100.minutes },
                                                   last_finished_at: {})

      expect(stalled).to eq([ "batch+ai" ])
    end
  end
end
