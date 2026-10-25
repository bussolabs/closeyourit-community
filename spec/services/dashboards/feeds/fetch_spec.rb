# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboards::Feeds::Fetch do
  let(:now) { Time.zone.parse("2026-10-25 10:00:00") }
  let(:earlier) { now - 1.hour }
  let(:feed) { create(:dashboards_feed, url: "https://service.example", token: "od_secret") }
  let(:endpoint) { "https://service.example/open-dashboard" }
  let(:report) do
    JSON.parse(Rails.root.join("contracts/open-dashboard/v1/fixtures/valid/complete.json").read)
  end

  before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

  it "stores a valid report, sends the key and clears the last failure" do
    feed.update!(last_error: "timeout")
    request = stub_request(:get, endpoint)
      .with(headers: { "Authorization" => "Bearer od_secret" })
      .to_return(status: 200, body: report.to_json, headers: { "Content-Type" => "application/json" })

    result = described_class.call(feed:, now:)

    expect(result).to be_ok
    expect(request).to have_been_requested
    expect(feed.reload).to have_attributes(payload: report, fetched_at: now, checked_at: now, last_error: nil)
  end

  context "when the read fails" do
    before { feed.update!(payload: report, fetched_at: earlier) }

    def expect_failure(code)
      result = described_class.call(feed:, now:)

      expect(result).not_to be_ok
      expect(result.error.code).to eq("R502-DASHBOARD-001")
      expect(feed.reload).to have_attributes(payload: report, fetched_at: earlier, checked_at: now, last_error: code)
    end

    { 401 => "unauthorized", 404 => "not_found", 500 => "http_500", 302 => "http_302" }.each do |status, code|
      it "keeps the last good report on HTTP #{status} and records #{code}" do
        stub_request(:get, endpoint).to_return(status:)

        expect_failure(code)
      end
    end

    it "rejects an answer that breaks the contract" do
      stub_request(:get, endpoint).to_return(status: 200, body: { open_dashboard: "1.0" }.to_json)

      expect_failure("invalid_payload")
    end

    it "rejects an answer that is not JSON" do
      stub_request(:get, endpoint).to_return(status: 200, body: "<html>")

      expect_failure("invalid_payload")
    end

    it "records a timeout" do
      stub_request(:get, endpoint).to_timeout

      expect_failure("timeout")
    end

    it "records an unreachable service" do
      stub_request(:get, endpoint).to_raise(SocketError)

      expect_failure("unreachable")
    end

    [ Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::DataError, IOError ].each do |error|
      it "records #{error} as an unreachable service" do
        stub_request(:get, endpoint).to_raise(error)

        expect_failure("unreachable")
      end
    end

    it "records an answer that is too large" do
      stub_request(:get, endpoint).to_return(status: 200, body: "x" * (described_class::MAX_BYTES + 1))

      expect_failure("too_large")
    end

    it "never calls an address inside the private network" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "10.0.0.5" ])

      expect_failure("blocked")
      expect(a_request(:get, endpoint)).not_to have_been_made
    end

    it "never calls a plain http address" do
      feed.update_column(:url, "http://service.example")

      expect_failure("blocked")
      expect(a_request(:get, "http://service.example/open-dashboard")).not_to have_been_made
    end
  end

  it "does not store a report read from an address that changed meanwhile" do
    stub_request(:get, endpoint).to_return do
      Dashboards::Feed.where(id: feed.id).update_all(url: "https://other.example")
      { status: 200, body: report.to_json }
    end

    described_class.call(feed:, now:)

    expect(feed.reload).to have_attributes(url: "https://other.example", payload: nil, fetched_at: nil, checked_at: nil)
  end
end
