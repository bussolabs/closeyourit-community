# frozen_string_literal: true

require "rails_helper"

# The public registries that say when a package version was published (CYRA-1167). A version the
# registry does not know is not a failure: there is simply no date.
RSpec.describe Vulnerabilities::Registry::Client do
  subject(:client) { described_class.new }

  def released_at(ecosystem, name, version) = client.released_at(ecosystem:, name:, version:)

  it "reads the version date from RubyGems" do
    stub_request(:get, "https://rubygems.org/api/v2/rubygems/rails/versions/7.0.0.json")
      .to_return(status: 200, body: { version_created_at: "2021-12-15T23:45:57.959Z" }.to_json)

    expect(released_at("RubyGems", "rails", "7.0.0")).to eq(Time.utc(2021, 12, 15, 23, 45, 57.959r))
  end

  it "reads the version date from the npm package document, escaping scoped names" do
    stub_request(:get, "https://registry.npmjs.org/@hotwired%2Fstimulus")
      .to_return(status: 200, body: { time: { "3.2.2" => "2023-08-07T09:29:58.028Z" } }.to_json)

    expect(released_at("npm", "@hotwired/stimulus", "3.2.2")).to eq(Time.utc(2023, 8, 7, 9, 29, 58.028r))
  end

  it "reads the version date from pub.dev" do
    stub_request(:get, "https://pub.dev/api/packages/http/versions/1.2.0")
      .to_return(status: 200, body: { published: "2024-01-16T22:46:38Z" }.to_json)

    expect(released_at("Pub", "http", "1.2.0")).to eq(Time.utc(2024, 1, 16, 22, 46, 38))
  end

  it "reads the version date from the Go module proxy, case-encoding the module path" do
    stub_request(:get, "https://proxy.golang.org/github.com/!burnt!sushi/toml/@v/v1.3.2.info")
      .to_return(status: 200, body: { Version: "v1.3.2", Time: "2023-06-08T06:13:15Z" }.to_json)

    expect(released_at("Go", "github.com/BurntSushi/toml", "1.3.2")).to eq(Time.utc(2023, 6, 8, 6, 13, 15))
  end

  it "returns nil for a version the registry does not know" do
    stub_request(:get, "https://rubygems.org/api/v2/rubygems/private-gem/versions/1.0.0.json")
      .to_return(status: 404, body: "")

    expect(released_at("RubyGems", "private-gem", "1.0.0")).to be_nil
  end

  it "returns nil when npm knows the package but not the version" do
    stub_request(:get, "https://registry.npmjs.org/left-pad")
      .to_return(status: 200, body: { time: { "1.0.0" => "2016-01-01T00:00:00Z" } }.to_json)

    expect(released_at("npm", "left-pad", "9.9.9")).to be_nil
  end

  it "returns nil for an ecosystem without a registry, without asking anyone" do
    expect(released_at("Debian:12", "openssl", "3.0.0")).to be_nil
  end

  it "turns a server error into a domain error" do
    stub_request(:get, "https://pub.dev/api/packages/http/versions/1.2.0").to_return(status: 503, body: "")

    expect { released_at("Pub", "http", "1.2.0") }
      .to raise_error(described_class::Error) { |error| expect(error.code).to eq("R502-REG-001") }
  end

  it "turns a timeout into a domain error" do
    stub_request(:get, "https://pub.dev/api/packages/http/versions/1.2.0").to_timeout

    expect { released_at("Pub", "http", "1.2.0") }.to raise_error(described_class::Error)
  end

  it "turns an unreachable registry into a domain error" do
    stub_request(:get, "https://pub.dev/api/packages/http/versions/1.2.0").to_raise(SocketError)

    expect { released_at("Pub", "http", "1.2.0") }.to raise_error(described_class::Error)
  end

  it "turns a body that is not JSON into a contract error" do
    stub_request(:get, "https://pub.dev/api/packages/http/versions/1.2.0").to_return(status: 200, body: "<html>")

    expect { released_at("Pub", "http", "1.2.0") }
      .to raise_error(described_class::Error) { |error| expect(error.code).to eq("R502-REG-002") }
  end

  it "returns nil when the date is missing or unreadable" do
    stub_request(:get, "https://pub.dev/api/packages/http/versions/1.2.0")
      .to_return(status: 200, body: { published: "not a date" }.to_json)

    expect(released_at("Pub", "http", "1.2.0")).to be_nil
  end
end
