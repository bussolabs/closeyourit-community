# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::SkillReleases::Sync do
  let(:entry_class) { Agents::SkillReleases::Feed::Entry }
  let(:listing_class) { Agents::SkillReleases::Feed::Listing }

  def listing(*entries, listed: entries.map(&:version))
    listing_class.new(entries:, listed: listed.to_set)
  end

  def entry(version, sha256: "a" * 64)
    entry_class.new(version:, url: "https://example.com/cyi-#{version}.tgz", sha256:, git_sha: nil, published_at: Time.current)
  end

  it "adds versions it has not seen and reports them" do
    create(:skill_release, version: "1.0.0")
    allow(Agents::SkillReleases::Feed).to receive(:call).and_return(listing(entry("1.0.0"), entry("1.1.0")))

    result = described_class.call

    expect(result.value[:added]).to eq([ "1.1.0" ])
    expect(Agents::SkillRelease.pluck(:version)).to contain_exactly("1.0.0", "1.1.0")
    created = Agents::SkillRelease.find_by!(version: "1.1.0")
    expect(created).to have_attributes(url: "https://example.com/cyi-1.1.0.tgz", sha256: "a" * 64)
    expect(created.published_at).to be_within(1.minute).of(Time.current)
  end

  it "skips an entry that cannot be saved and keeps the others" do
    entries = [ entry("1.1.0"), entry("1.2.0") ]
    allow(Agents::SkillReleases::Feed).to receive(:call).and_return(listing(*entries))
    allow(Rails.logger).to receive(:warn)
    allow(Agents::SkillRelease).to receive(:create!).and_wrap_original do |original, attrs|
      raise ActiveRecord::RecordNotUnique, "duplicate" if attrs[:version] == "1.1.0"

      original.call(attrs)
    end

    result = described_class.call

    expect(result.value[:added]).to eq([ "1.2.0" ])
    expect(Rails.logger).to have_received(:warn).with(/1\.1\.0/)
  end

  it "skips an invalid entry" do
    allow(Agents::SkillReleases::Feed).to receive(:call).and_return(listing(entry("1.1.0", sha256: "short"), entry("1.2.0")))
    allow(Rails.logger).to receive(:warn)

    expect(described_class.call.value[:added]).to eq([ "1.2.0" ])
  end

  it "never rewrites the sha256 of a known version, and logs the mismatch" do
    known = create(:skill_release, version: "1.0.0", sha256: "b" * 64)
    allow(Agents::SkillReleases::Feed).to receive(:call).and_return(listing(entry("1.0.0", sha256: "c" * 64)))
    allow(Rails.logger).to receive(:warn)

    described_class.call

    expect(known.reload.sha256).to eq("b" * 64)
    expect(Rails.logger).to have_received(:warn).with(/1\.0\.0.*sha256/)
  end

  it "keeps the list and returns an error when the feed fails" do
    create(:skill_release, version: "1.0.0")
    allow(Agents::SkillReleases::Feed).to receive(:call).and_raise(Agents::SkillReleases::Feed::Error, "down")

    result = described_class.call

    expect(result).not_to be_ok
    expect(result.error.code).to eq("R502-AGENT-001")
    expect(Agents::SkillRelease.count).to eq(1)
  end

  describe "GitHub decides which versions are withdrawn" do
    it "withdraws a known version GitHub no longer lists, and restores it when it is listed again" do
      kept = create(:skill_release, version: "1.0.0")
      gone = create(:skill_release, version: "1.1.0")
      allow(Agents::SkillReleases::Feed).to receive(:call).and_return(listing(entry("1.0.0")))

      result = described_class.call

      expect(result.value[:withdrawn]).to eq([ "1.1.0" ])
      expect(gone.reload).to be_withdrawn
      expect(kept.reload).not_to be_withdrawn

      allow(Agents::SkillReleases::Feed).to receive(:call).and_return(listing(entry("1.0.0"), entry("1.1.0")))
      expect(described_class.call.value[:restored]).to eq([ "1.1.0" ])
      expect(gone.reload).not_to be_withdrawn
    end

    it "keeps a version that is still published even if its package became unreadable" do
      known = create(:skill_release, version: "1.0.0")
      allow(Agents::SkillReleases::Feed).to receive(:call).and_return(listing(listed: [ "1.0.0" ]))

      described_class.call

      expect(known.reload).not_to be_withdrawn
    end

    it "withdraws nothing when GitHub lists no version at all" do
      known = create(:skill_release, version: "1.0.0")
      allow(Agents::SkillReleases::Feed).to receive(:call).and_return(listing)
      allow(Rails.logger).to receive(:warn)

      described_class.call

      expect(known.reload).not_to be_withdrawn
      expect(Rails.logger).to have_received(:warn).with(/no published version/)
    end
  end
end
