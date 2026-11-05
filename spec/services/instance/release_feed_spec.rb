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

  describe "channels (CYRA-1160)" do
    def stub_list(*tags, drafts: [])
      body = tags.map { |tag| { tag_name: tag, draft: false } } + drafts.map { |tag| { tag_name: tag, draft: true } }
      stub_request(:get, "#{api}/releases?per_page=30").to_return(status: 200, body: body.to_json)
    end

    it "offers the newest beta on the beta channel, with its own changes" do
      stub_list("v1.5.0", "v1.6.0-beta.2", "v1.6.0-beta.10", "v1.5.1-rc.1", drafts: %w[v1.7.0-beta.1])
      text = "## [Unreleased]\n\n### Added\n\n- **Beta thing.** New.\n\n#{changelog}"
      stub_request(:get, "#{raw}/v1.6.0-beta.10/CHANGELOG.md").to_return(status: 200, body: text)

      release = described_class.call(current: "v1.4.2", channel: "beta")

      expect(release.version).to eq("1.6.0-beta.10")
      expect(release.notes.map(&:version)).to eq(%w[1.6.0-beta.10 1.5.0 1.4.3])
    end

    it "offers the stable once it is out to an install on its beta" do
      stub_list("v1.6.0", "v1.6.0-beta.3")
      stub_request(:get, "#{raw}/v1.6.0/CHANGELOG.md").to_return(status: 404)

      expect(described_class.call(current: "v1.6.0-beta.3", channel: "beta").version).to eq("1.6.0")
    end

    it "never asks the full list on the stable channel, so a newer beta stays unseen" do
      stub_latest("v1.4.2")
      list = stub_list("v1.6.0-beta.1")

      expect(described_class.call(current: "v1.4.2", channel: "stable")).to be_nil
      expect(list).not_to have_been_requested
    end

    it "refuses a beta handed out as the latest stable release" do
      stub_latest("v1.6.0-beta.1")

      expect { described_class.call(current: "v1.4.2") }.to raise_error(Instance::ReleaseFeed::Error, /unexpected release tag/)
    end

    it "raises a feed error when the beta list has no version" do
      stub_list("nightly")

      expect { described_class.call(current: "v1.4.2", channel: "beta") }.to raise_error(Instance::ReleaseFeed::Error)
    end
  end

  it "reads from the mirror set in the environment" do
    stub_const("ENV", ENV.to_h.merge("CLOSEYOURIT_RELEASES_API" => "http://mirror.test/api",
                                      "CLOSEYOURIT_RELEASES_RAW" => "http://mirror.test/raw"))
    stub_request(:get, "http://mirror.test/api/releases/latest").to_return(status: 200, body: { tag_name: "v1.5.0" }.to_json)
    stub_request(:get, "http://mirror.test/raw/v1.5.0/CHANGELOG.md").to_return(status: 200, body: changelog)

    expect(described_class.call(current: "v1.4.2").version).to eq("1.5.0")
  end
end
