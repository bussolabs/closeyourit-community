# frozen_string_literal: true

require "rails_helper"

# CYRA-1197 — an item the machine keeps failing to judge must not hold back the ones behind it.
RSpec.describe Agents::Supporters::OfferLimit do
  let(:host) { create(:agent_host) }

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  it "rests an item offered the maximum number of times without a verdict" do
    (described_class::MAX_OFFERS - 1).times { described_class.offered!(host, "sha256:a") }
    expect(described_class.resting?(host, "sha256:a")).to be(false)

    described_class.offered!(host, "sha256:a")

    expect(described_class.resting?(host, "sha256:a")).to be(true)
    expect(described_class.resting?(host, "sha256:b")).to be(false)
    expect(described_class.resting?(create(:agent_host), "sha256:a")).to be(false)
  end

  it "offers the item again once the window has passed" do
    described_class::MAX_OFFERS.times { described_class.offered!(host, "sha256:a") }

    travel_to(described_class::WINDOW.from_now + 1.minute) do
      expect(described_class.resting?(host, "sha256:a")).to be(false)
    end
  end
end
