# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::SkillRelease do
  it "accepts plain SemVer only" do
    expect(build(:skill_release, version: "1.2.3")).to be_valid
    expect(build(:skill_release, version: "v1.2.3")).not_to be_valid
    expect(build(:skill_release, version: "1.2")).not_to be_valid
    expect(build(:skill_release, version: "1.2.3-beta")).not_to be_valid
  end

  it "requires a 64-char lowercase hex sha256 and an https url" do
    expect(build(:skill_release, sha256: "A" * 64)).to be_valid # normalized to lowercase
    expect(build(:skill_release, sha256: "abc")).not_to be_valid
    expect(build(:skill_release, url: "http://example.com/cyi.tgz")).not_to be_valid
  end

  it "keeps versions unique" do
    create(:skill_release, version: "1.0.0")
    expect(build(:skill_release, version: "1.0.0")).not_to be_valid
  end

  it "picks the highest available version by SemVer, not by text" do
    create(:skill_release, version: "1.9.0")
    create(:skill_release, version: "1.10.0")
    create(:skill_release, version: "2.0.0", withdrawn_at: Time.current)

    expect(described_class.latest_available.version).to eq("1.10.0")
  end
end
