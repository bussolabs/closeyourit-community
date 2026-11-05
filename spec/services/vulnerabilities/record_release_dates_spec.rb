# frozen_string_literal: true

require "rails_helper"

# CYRA-1167 — the release date is asked only for versions that appeared in a project less than 72
# hours ago, once per version for every project, and a silent registry never stops the scan.
RSpec.describe Vulnerabilities::RecordReleaseDates do
  let(:now) { Time.current }
  let(:client) { instance_double(Vulnerabilities::Registry::Client) }
  let(:released) { 1.day.ago.utc.change(usec: 0) }

  def package(name, appeared: 1.hour.ago, version: "1.0.0")
    create(:vulnerability_package, name: name, version: version, created_at: appeared)
  end

  def record(packages) = described_class.call(packages: packages, client: client, now: now)

  it "stores the date of a version that appeared less than 72 hours ago" do
    allow(client).to receive(:released_at).and_return(released)

    record([ package("rack") ])

    release = Vulnerabilities::PackageRelease.sole
    expect([ release.ecosystem, release.name, release.version ]).to eq([ "RubyGems", "rack", "1.0.0" ])
    expect(release.released_at).to eq(released)
  end

  it "does not ask for versions that appeared more than 72 hours ago" do
    allow(client).to receive(:released_at)

    record([ package("rack", appeared: 73.hours.ago) ])

    expect(client).not_to have_received(:released_at)
  end

  it "asks once for the same version seen in two projects, and never again once known" do
    allow(client).to receive(:released_at).and_return(released)

    record([ package("rack"), package("rack") ])
    record([ package("rack") ])

    expect(client).to have_received(:released_at).once
  end

  it "stores nothing when the registry does not know the version" do
    allow(client).to receive(:released_at).and_return(nil)

    expect(record([ package("private-gem") ])).to be_ok
    expect(Vulnerabilities::PackageRelease.count).to eq(0)
  end

  it "leaves the date empty on a registry failure and asks again on the next run" do
    rack = package("rack")
    allow(client).to receive(:released_at)
      .and_raise(Vulnerabilities::Registry::Client::Error.new("down", code: "R502-REG-001"))

    expect(record([ rack ])).to be_ok
    expect(Vulnerabilities::PackageRelease.count).to eq(0)

    allow(client).to receive(:released_at).and_return(released)
    record([ rack ])

    expect(Vulnerabilities::PackageRelease.count).to eq(1)
  end

  it "stops asking a registry that failed for the rest of the run" do
    allow(client).to receive(:released_at)
      .and_raise(Vulnerabilities::Registry::Client::Error.new("down", code: "R502-REG-001"))

    record([ package("rack"), package("rake"), package("thor") ])

    expect(client).to have_received(:released_at).once
  end
end
