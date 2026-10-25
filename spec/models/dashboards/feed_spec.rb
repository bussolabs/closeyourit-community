# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboards::Feed do
  it "is valid with a public https url and a token" do
    expect(build(:dashboards_feed)).to be_valid
  end

  {
    "plain http" => "http://service.example",
    "a private ip" => "https://10.0.0.5",
    "loopback" => "https://127.0.0.1",
    "credentials in the url" => "https://user:pass@service.example",
    "a query string" => "https://service.example?x=1",
    "no host" => "https://",
    "garbage" => "not a url"
  }.each do |name, url|
    it "refuses #{name}" do
      feed = build(:dashboards_feed, url:)

      expect(feed).not_to be_valid
      expect(feed.errors[:url]).to be_present
    end
  end

  it "requires a token" do
    expect(build(:dashboards_feed, token: nil)).not_to be_valid
  end

  it "allows one feed per project" do
    feed = create(:dashboards_feed)

    expect(build(:dashboards_feed, project: feed.project)).not_to be_valid
  end

  it "stores the token encrypted" do
    feed = create(:dashboards_feed, token: "od_plaintext")
    raw = described_class.connection.select_value(
      described_class.where(id: feed.id).select(:token).to_sql
    )

    expect(raw).not_to include("od_plaintext")
    expect(feed.reload.token).to eq("od_plaintext")
  end

  it "builds the endpoint with or without a trailing slash" do
    expect(build(:dashboards_feed, url: "https://service.example").endpoint).to eq("https://service.example/open-dashboard")
    expect(build(:dashboards_feed, url: "https://service.example/app/").endpoint).to eq("https://service.example/app/open-dashboard")
  end

  it "is removed with its project" do
    feed = create(:dashboards_feed)

    expect { feed.project.destroy! }.to change(described_class, :count).by(-1)
  end

  it "lists only enabled feeds in .enabled" do
    on = create(:dashboards_feed)
    create(:dashboards_feed, enabled: false)

    expect(described_class.enabled).to contain_exactly(on)
  end

  it "shows an Italian message for a bad url" do
    feed = build(:dashboards_feed, url: "http://service.example")
    feed.valid?

    I18n.with_locale(:it) { expect(feed.errors.full_messages_for(:url).first).to include("https") }
  end
end
