# frozen_string_literal: true

require "rails_helper"

# CYRA-1163 — the guarded reader with the caller's cap, accepted type and binary body. The SEO defaults
# are covered, unchanged, by fetch_spec.rb.
RSpec.describe Seo::Fetch, type: :service do
  before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

  it "stops at the cap the caller chose" do
    stub_request(:get, "https://site.test/").to_return(status: 200, body: "a" * 5_000)

    result = described_class.call(url: "https://site.test/", max_bytes: 1_000)

    expect(result).to be_truncated
    expect(result.body.bytesize).to eq(1_000)
  end

  it "asks for the type the caller accepts" do
    stub = stub_request(:get, "https://site.test/logo.png").with(headers: { "Accept" => "image/png" })
                                                           .to_return(status: 200, body: "png")

    described_class.call(url: "https://site.test/logo.png", accept: "image/png")

    expect(stub).to have_been_requested
  end

  it "keeps a binary body as bytes instead of text" do
    bytes = "\x89PNG\r\n\x1A\n\xFF\xFE".b
    stub_request(:get, "https://site.test/logo.png").to_return(status: 200, body: bytes)

    result = described_class.call(url: "https://site.test/logo.png", binary: true)

    expect(result.body.encoding).to eq(Encoding::BINARY)
    expect(result.body).to eq(bytes)
  end

  it "still refuses an internal address with the new options" do
    allow(NetworkGuard).to receive(:resolve).and_return([ "10.0.0.9" ])
    stub = stub_request(:get, "https://inside.test/logo.png")

    result = described_class.call(url: "https://inside.test/logo.png", binary: true, max_bytes: 10)

    expect(result).to be_blocked
    expect(stub).not_to have_been_requested
  end
end
