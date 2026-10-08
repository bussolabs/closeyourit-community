# spec/services/agents/skill_releases/pin_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::SkillReleases::Pin do
  let(:organization) { create(:organization) }
  let(:actor) { create(:account) }

  it "pins an available version and replaces an earlier pin" do
    create(:skill_release, version: "1.0.0")
    create(:skill_release, version: "1.1.0")

    described_class.call(organization:, version: "1.0.0", actor:)
    result = described_class.call(organization:, version: "1.1.0", actor:)

    expect(result.value.skill_release.version).to eq("1.1.0")
    expect(Agents::SkillReleasePin.where(organization:).count).to eq(1)
  end

  it "accepts a version with a leading v" do
    create(:skill_release, version: "1.0.0")

    expect(described_class.call(organization:, version: "v1.0.0", actor:).value.skill_release.version).to eq("1.0.0")
  end

  it "refuses unknown and withdrawn versions with R422-AGENT-010" do
    create(:skill_release, version: "1.0.0", withdrawn_at: Time.current)

    expect(described_class.call(organization:, version: "9.9.9", actor:).error.code).to eq("R422-AGENT-010")
    expect(described_class.call(organization:, version: "1.0.0", actor:).error.code).to eq("R422-AGENT-010")
  end

  it "unpins idempotently" do
    create(:skill_release_pin, organization:)

    2.times { expect(Agents::SkillReleases::Unpin.call(organization:)).to be_ok }
    expect(organization.reload.skill_release_pin).to be_nil
  end
end
