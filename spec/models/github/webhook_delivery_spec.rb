# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::WebhookDelivery do
  include ActiveJob::TestHelper

  def receive_delivery(body: '{"action":"deleted"}', delivery_id: "receipt", event: "installation")
    described_class.receive(delivery_id:, event:, body:)
  end

  it "enforces uniqueness independently for content and delivery identifier" do
    receipt = receive_delivery
    expect(receive_delivery(delivery_id: "renamed")).to eq(receipt)
    expect { receive_delivery(body: "{}") }.to raise_error(described_class::ConflictingDelivery)
    expect(described_class.count).to eq(1)
  end

  it "keeps receipts with no delivery identifier deduplicated by content" do
    expect(receive_delivery(delivery_id: nil)).to eq(receive_delivery(delivery_id: nil))
  end

  it "rolls back application changes and completion together after interruption" do
    receipt = receive_delivery
    organization = create(:organization)
    original_name = organization.name
    expect do
      receipt.process do
        organization.update!(name: "Interrupted")
        raise "worker interrupted"
      end
    end.to raise_error("worker interrupted")
    expect(organization.reload.name).to eq(original_name)
    expect(receipt.reload.completed_at).to be_nil
    expect(receipt.body).to be_present
    receipt.process { organization.update!(name: "Recovered") }
    expect(organization.reload.name).to eq("Recovered")
    expect(receipt.reload.completed_at).to be_present
    expect(receipt.body).to be_nil
  end

  it "never expires completed receipts" do
    receipt = receive_delivery
    receipt.process { nil }
    travel_to 1.year.from_now do
      expect(receive_delivery(delivery_id: "renamed")).to eq(receipt)
      expect { receipt.process { raise "replayed" } }.not_to raise_error
      expect { receipt.enqueue }.not_to have_enqueued_job(Github::WebhookJob)
    end
  end

  it "recovers an interrupted enqueue and a stale queued receipt" do
    receipt = receive_delivery
    expect { Github::RecoverWebhooksJob.perform_now }.to have_enqueued_job(Github::WebhookJob)
    expect { Github::RecoverWebhooksJob.perform_now }.not_to have_enqueued_job(Github::WebhookJob)
    travel_to 11.minutes.from_now do
      expect { Github::RecoverWebhooksJob.perform_now }.to have_enqueued_job(Github::WebhookJob)
    end
    expect(receipt.reload.completed_at).to be_nil
  end

  it "keeps a refused enqueue available for recovery" do
    receipt = receive_delivery
    allow(Github::WebhookJob).to receive(:perform_later).and_return(false)
    receipt.enqueue
    expect(receipt.reload.enqueued_at).to be_nil
  end

  [ "[]", "invalid", "" ].each do |body|
    it "normalizes malformed content #{body.inspect} only at processing time" do
      receipt = receive_delivery(body:)
      expect { |block| receipt.process(&block) }.to yield_with_args("installation", {})
    end
  end
end
