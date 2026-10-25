# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboards::FetchFeedJob, type: :job do
  it "reads an enabled feed" do
    feed = create(:dashboards_feed)
    expect(Dashboards::Feeds::Fetch).to receive(:call).with(feed:)

    described_class.perform_now(feed.id)
  end

  it "skips a paused feed" do
    feed = create(:dashboards_feed, enabled: false)
    expect(Dashboards::Feeds::Fetch).not_to receive(:call)

    described_class.perform_now(feed.id)
  end

  it "does nothing when the feed is gone" do
    expect(Dashboards::Feeds::Fetch).not_to receive(:call)

    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end
end
