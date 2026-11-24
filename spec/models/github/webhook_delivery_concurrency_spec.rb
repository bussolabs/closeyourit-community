# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::WebhookDelivery, "concurrency" do
  self.use_transactional_tests = false

  after { described_class.delete_all }

  def concurrently
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.map(&:value)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  it "records concurrent copies once even when their identifiers differ" do
    receipts = concurrently do
      described_class.receive(delivery_id: SecureRandom.uuid, event: "installation", body: "{}")
    end
    expect(receipts.map(&:id).uniq.size).to eq(1)
    expect(described_class.count).to eq(1)
  end

  it "serializes concurrent workers and applies the handler only once" do
    receipt = described_class.receive(delivery_id: "concurrent", event: "installation", body: "{}")
    calls = Queue.new
    allow(Github::Webhooks::Installation).to receive(:call) do
      calls << true
      nil
    end
    concurrently { Github::WebhookJob.perform_now(delivery_id: receipt.id) }
    expect(calls.size).to eq(1)
    expect(receipt.reload.completed_at).to be_present
  end

  it "records simultaneous deliveries with the same identifier once" do
    receipts = concurrently do
      described_class.receive(delivery_id: "same", event: "installation", body: "{}")
    end
    expect(receipts.map(&:id).uniq.size).to eq(1)
  end
end
