# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::ChannelReservation do
  let(:channel) { create(:alerting_channel) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:key) { "alerting:channel:#{channel.id}:window" }

  before do
    allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
    allow(Rails).to receive(:cache).and_return(cache)
  end

  it "allows one owner until expiry and rejects a stale release after reacquisition" do
    freeze_time do
      original = described_class.acquire(channel:, key:, expires_in: 10.seconds)
      expect(original).to be_present
      expect(described_class.acquire(channel: Alerting::Channel.find(channel.id), key:, expires_in: 10.seconds)).to be_nil

      travel 11.seconds
      successor = described_class.acquire(channel: Alerting::Channel.find(channel.id), key:, expires_in: 10.seconds)
      expect(successor).to be_present
      expect(successor).not_to eq(original)

      described_class.release(channel_id: channel.id, key:, token: original)
      expect(cache.read(key)).to eq(successor)

      described_class.release(channel_id: channel.id, key:, token: successor)
      expect(described_class.acquire(channel:, key:, expires_in: 10.seconds)).to be_present
    end
  end
end
