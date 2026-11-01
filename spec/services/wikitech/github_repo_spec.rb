# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::GithubRepo do
  let(:repo_url) { "https://github.com/godotengine/godot" }
  let(:api) { "https://api.github.com/repos/godotengine/godot" }

  it "returns the public data of the repository" do
    stub_request(:get, api).to_return(status: 200, body: {
      full_name: "godotengine/godot", stargazers_count: 100_000, license: { spdx_id: "MIT" },
      language: "C++", pushed_at: "2026-10-30T10:00:00Z", archived: false, description: "Game engine"
    }.to_json)

    meta = described_class.call(repo_url: repo_url).value

    expect(meta).to include("full_name" => "godotengine/godot", "stars" => 100_000, "license" => "MIT",
                            "language" => "C++", "description" => "Game engine")
  end

  it "shows no license when GitHub cannot tell it" do
    stub_request(:get, api).to_return(status: 200, body: { license: { spdx_id: "NOASSERTION" } }.to_json)

    expect(described_class.call(repo_url: repo_url).value["license"]).to be_nil
  end

  it "answers not found for a repository that does not exist" do
    stub_request(:get, api).to_return(status: 404, body: "{}")

    expect(described_class.call(repo_url: repo_url).error.code).to eq(described_class::NOT_FOUND)
  end

  it "asks to wait when the rate limit is reached" do
    stub_request(:get, api).to_return(status: 403, headers: { "x-ratelimit-reset" => (Time.current.to_i + 600).to_s })

    expect { described_class.call(repo_url: repo_url) }
      .to raise_error(described_class::RateLimited) { |error| expect(error.retry_after).to be_between(590, 600) }
  end

  it "prefers the retry-after header and falls back to an hour" do
    stub_request(:get, api).to_return({ status: 429, headers: { "retry-after" => "30" } }, { status: 429 })

    expect { described_class.call(repo_url: repo_url) }.to raise_error(described_class::RateLimited) { |e| expect(e.retry_after).to eq(30) }
    expect { described_class.call(repo_url: repo_url) }.to raise_error(described_class::RateLimited) { |e| expect(e.retry_after).to eq(3600) }
  end

  it "reports other answers as a temporary failure" do
    stub_request(:get, api).to_return(status: 502)

    expect(described_class.call(repo_url: repo_url).error.code).to eq(described_class::UNAVAILABLE)
  end
end
