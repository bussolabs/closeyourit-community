# frozen_string_literal: true

require "rails_helper"

RSpec.describe Instance::ReleaseFeed do
  let(:api) { "https://api.github.com/repos/bussolabs/closeyourit-community" }
  let(:raw) { "https://raw.githubusercontent.com/bussolabs/closeyourit-community" }
  let(:changelog) do
    <<~MD
      # Changelog

      ## [Unreleased]

      ## [1.5.0] - 2026-10-20

      ### Added

      - **Shared views.** Saved filters for the whole team.

      ## [1.4.3] - 2026-10-10

      ### Fixed

      - **Faster logs.** Searching logs is quicker.

      ## [1.4.2] - 2026-10-01

      ### Fixed

      - **Old entry.** Already installed.
    MD
  end

  def stub_latest(tag) = stub_request(:get, "#{api}/releases/latest").to_return(status: 200, body: { tag_name: tag }.to_json)

  it "returns the newer release with the changelog entries the install does not have yet" do
    stub_latest("v1.5.0")
    stub_request(:get, "#{raw}/v1.5.0/CHANGELOG.md").to_return(status: 200, body: changelog)

    release = described_class.call(current: "v1.4.2")

    expect(release.version).to eq("1.5.0")
    expect(release.notes.map(&:version)).to eq(%w[1.5.0 1.4.3])
  end

  it "reads the changelog as UTF-8, whatever encoding the response carries" do
    stub_latest("v1.5.0")
    body = "## [1.5.0] - 2026-10-20\n\n### Fixed\n\n- **Log più veloci.** Più rapidi.\n".b
    stub_request(:get, "#{raw}/v1.5.0/CHANGELOG.md").to_return(status: 200, body:)

    item = described_class.call(current: "v1.4.2").notes.first.sections.first[:items].first

    expect(item).to include("più veloci")
    expect(item.encoding).to eq(Encoding::UTF_8)
  end

  it "returns nil when the install already runs the latest release" do
    stub_latest("v1.4.2")

    expect(described_class.call(current: "v1.4.2")).to be_nil
  end

  it "returns nil when the latest release is older than the install" do
    stub_latest("v1.4.0")

    expect(described_class.call(current: "v1.4.2")).to be_nil
  end

  it "keeps the release without notes when the changelog cannot be read" do
    stub_latest("v1.5.0")
    stub_request(:get, "#{raw}/v1.5.0/CHANGELOG.md").to_return(status: 404)

    release = described_class.call(current: "v1.4.2")

    expect(release.version).to eq("1.5.0")
    expect(release.notes).to eq([])
  end

  it "raises a feed error when the release list cannot be read" do
    stub_request(:get, "#{api}/releases/latest").to_return(status: 503)

    expect { described_class.call(current: "v1.4.2") }.to raise_error(Instance::ReleaseFeed::Error)
  end

  it "refuses a tag that is not a plain version" do
    stub_latest("v1.5.0/../../evil")

    expect { described_class.call(current: "v1.4.2") }.to raise_error(Instance::ReleaseFeed::Error)
  end

  it "reads from the mirror set in the environment" do
    stub_const("ENV", ENV.to_h.merge("CLOSEYOURIT_RELEASES_API" => "http://mirror.test/api",
                                      "CLOSEYOURIT_RELEASES_RAW" => "http://mirror.test/raw"))
    stub_request(:get, "http://mirror.test/api/releases/latest").to_return(status: 200, body: { tag_name: "v1.5.0" }.to_json)
    stub_request(:get, "http://mirror.test/raw/v1.5.0/CHANGELOG.md").to_return(status: 200, body: changelog)

    expect(described_class.call(current: "v1.4.2").version).to eq("1.5.0")
  end
end
