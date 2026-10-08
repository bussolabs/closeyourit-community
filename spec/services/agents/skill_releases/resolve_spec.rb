# spec/services/agents/skill_releases/resolve_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::SkillReleases::Resolve do
  let(:organization) { create(:organization) }

  it "gives the latest available version when nothing is pinned" do
    create(:skill_release, version: "1.0.0")
    create(:skill_release, version: "1.2.0")
    create(:skill_release, version: "1.3.0", withdrawn_at: Time.current)

    value = described_class.call(organization:).value
    expect(value).to include(version: "1.2.0", pinned: false, pinned_version: nil, pin_withdrawn: false)
  end

  it "gives the pinned version, older ones included" do
    old = create(:skill_release, version: "1.0.0")
    create(:skill_release, version: "1.2.0")
    create(:skill_release_pin, organization:, skill_release: old)

    expect(described_class.call(organization:).value).to include(version: "1.0.0", pinned: true, pinned_version: "1.0.0")
  end

  it "falls back to the latest and says so when the pinned version was withdrawn" do
    old = create(:skill_release, version: "1.0.0", withdrawn_at: Time.current)
    create(:skill_release, version: "1.2.0")
    create(:skill_release_pin, organization:, skill_release: old)

    expect(described_class.call(organization:).value)
      .to include(version: "1.2.0", pinned: true, pinned_version: "1.0.0", pin_withdrawn: true)
  end

  it "returns a nil git_sha when the release has none" do
    create(:skill_release, version: "1.0.0", git_sha: nil)

    expect(described_class.call(organization:).value).to include(version: "1.0.0", git_sha: nil)
  end

  it "answers R404-AGENT-009 when no version is available" do
    result = described_class.call(organization:)

    expect(result.error.code).to eq("R404-AGENT-009")
  end
end
