# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::SkillReleases::Feed do
  let(:api) { "https://api.github.com/repos/bussolabs/cyi-skills" }
  let(:sha) { "a" * 64 }

  def release(tag, body: "sha256: #{"a" * 64}", draft: false, prerelease: false, assets: nil)
    version = tag.delete_prefix("v")
    {
      tag_name: tag, draft:, prerelease:, body:, target_commitish: "b" * 40, published_at: "2026-10-08T10:00:00Z",
      assets: assets || [ { name: "cyi-#{version}.tgz", browser_download_url: "https://github.com/x/releases/download/#{tag}/cyi-#{version}.tgz" } ]
    }
  end

  def stub_releases(*releases)
    stub_request(:get, "#{api}/releases?per_page=100&page=1").to_return(status: 200, body: releases.to_json)
  end

  it "returns published releases with their package url and sha256" do
    stub_releases(release("v1.2.0"))

    entry = described_class.call.entries.sole
    expect(entry).to have_attributes(version: "1.2.0", sha256: sha, git_sha: "b" * 40,
                                     url: "https://github.com/x/releases/download/v1.2.0/cyi-1.2.0.tgz")
    expect(entry.published_at).to eq(Time.zone.parse("2026-10-08T10:00:00Z"))
  end

  it "skips drafts, prereleases, odd tags, and releases without package or sha256" do
    stub_releases(
      release("v1.0.0", draft: true), release("v1.1.0", prerelease: true), release("v1.2.0-rc1"),
      release("v1.3.0", assets: []), release("v1.4.0", body: "no hash here")
    )

    expect(described_class.call.entries).to be_empty
  end

  it "reads the mirror when one is configured" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CLOSEYOURIT_SKILLS_RELEASES_API").and_return("https://mirror.example.com/skills")
    stub_request(:get, "https://mirror.example.com/skills/releases?per_page=100&page=1").to_return(status: 200, body: "[]")

    expect(described_class.call.entries).to eq([])
  end

  it "raises Feed::Error when GitHub is unreachable or answers badly" do
    stub_request(:get, "#{api}/releases?per_page=100&page=1").to_timeout
    expect { described_class.call }.to raise_error(described_class::Error)

    stub_request(:get, "#{api}/releases?per_page=100&page=1").to_return(status: 500, body: "")
    expect { described_class.call }.to raise_error(described_class::Error)

    stub_request(:get, "#{api}/releases?per_page=100&page=1").to_return(status: 200, body: "not json")
    expect { described_class.call }.to raise_error(described_class::Error)
  end

  describe "bad items do not block the good ones" do
    let(:good) { release("v1.0.0") }

    def expect_only_good(*bad)
      stub_releases(*bad, good)
      allow(Rails.logger).to receive(:warn)

      expect(described_class.call.entries.map(&:version)).to eq([ "1.0.0" ])
    end

    it "skips a non-Hash item" do
      expect_only_good("oops", 42)
    end

    it "skips malformed assets" do
      expect_only_good(release("v1.1.0").merge(assets: [ "x", nil ]), release("v1.2.0").merge(assets: 7))
    end

    it "skips a missing or unparseable published_at" do
      expect_only_good(release("v1.1.0").merge(published_at: nil), release("v1.2.0").merge(published_at: "not a date"))
    end

    it "skips a package url that is not https" do
      bad = release("v1.1.0", assets: [ { name: "cyi-1.1.0.tgz", browser_download_url: "http://example.com/cyi-1.1.0.tgz" } ])
      expect_only_good(bad)
    end
  end

  it "raises Feed::Error when the connection is cut" do
    stub_request(:get, "#{api}/releases?per_page=100&page=1").to_raise(EOFError)
    expect { described_class.call }.to raise_error(described_class::Error)

    stub_request(:get, "#{api}/releases?per_page=100&page=1").to_raise(Net::HTTPBadResponse)
    expect { described_class.call }.to raise_error(described_class::Error)

    stub_request(:get, "#{api}/releases?per_page=100&page=1").to_raise(Zlib::Error)
    expect { described_class.call }.to raise_error(described_class::Error)
  end

  it "lists every published version, including one whose package cannot be read" do
    stub_releases(release("v1.0.0"), release("v1.1.0", assets: []), release("v1.2.0", prerelease: true),
                  release("v1.3.0", draft: true))
    allow(Rails.logger).to receive(:warn)

    listing = described_class.call
    expect(listing.entries.map(&:version)).to eq([ "1.0.0" ])
    expect(listing.listed).to contain_exactly("1.0.0", "1.1.0")
  end

  it "reads every page of releases" do
    first = (0...100).map { |i| release("v0.0.#{i}") }
    stub_request(:get, "#{api}/releases?per_page=100&page=1").to_return(status: 200, body: first.to_json)
    stub_request(:get, "#{api}/releases?per_page=100&page=2").to_return(status: 200, body: [ release("v1.0.0") ].to_json)

    expect(described_class.call.listed).to include("0.0.0", "0.0.99", "1.0.0")
  end
end
