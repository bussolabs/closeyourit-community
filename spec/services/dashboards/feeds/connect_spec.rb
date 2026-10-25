# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboards::Feeds::Connect do
  let(:project) { create(:project) }

  it "creates the feed with a new key and returns the key once" do
    result = described_class.call(project:, url: "https://service.example")

    expect(result).to be_ok
    expect(result.value[:token]).to match(/\Aod_[A-Za-z0-9]{40}\z/)
    expect(project.reload.dashboard_feed).to have_attributes(
      url: "https://service.example", token: result.value[:token], enabled: true
    )
  end

  it "replaces the key and keeps the last report when the address stays the same" do
    first = described_class.call(project:, url: "https://service.example").value[:token]
    project.dashboard_feed.update!(payload: { "open_dashboard" => "1.0" }, last_error: "unauthorized")

    second = described_class.call(project:, url: "https://service.example").value[:token]

    expect(second).not_to eq(first)
    expect(project.reload.dashboard_feed).to have_attributes(token: second, payload: { "open_dashboard" => "1.0" })
    expect(Dashboards::Feed.where(project:).count).to eq(1)
  end

  it "forgets the old report when the address changes" do
    described_class.call(project:, url: "https://service.example")
    project.dashboard_feed.update!(payload: { "open_dashboard" => "1.0" }, fetched_at: Time.current, last_error: "timeout")

    described_class.call(project:, url: "https://other.example")

    expect(project.reload.dashboard_feed).to have_attributes(
      url: "https://other.example", payload: nil, fetched_at: nil, last_error: nil
    )
  end

  it "turns a paused feed back on" do
    create(:dashboards_feed, project:, enabled: false)

    described_class.call(project:, url: "https://service.example")

    expect(project.reload.dashboard_feed).to be_enabled
  end

  it "refuses an address that is not public https and saves nothing" do
    result = described_class.call(project:, url: "http://service.example")

    expect(result).not_to be_ok
    expect(result.error.code).to eq("R422-DASHBOARD-001")
    expect(result.error.details).to have_key(:url)
    expect(project.reload.dashboard_feed).to be_nil
  end
end
