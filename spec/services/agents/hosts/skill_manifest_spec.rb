# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Hosts::SkillManifest do
  let(:organization) { create(:organization) }

  it "ok: serve version/digest/repo/ref del bundle pinnato (version è la stringa del pin, non 1)" do
    create(:agent_skill_bundle, organization:, repo: "bussolabs/closeyourit-skills", ref: "v0.2.0", version: "0.2.0", digest: "b" * 40)

    result = described_class.call(organization:)

    expect(result).to be_ok
    expect(result.value).to eq(version: "0.2.0", digest: "b" * 40, repo: "bussolabs/closeyourit-skills", ref: "v0.2.0")
  end

  it "err R404-AGENT-004 quando l'org non ha un bundle pinnato" do
    result = described_class.call(organization:)

    expect(result).not_to be_ok
    expect(result.error.code).to eq("R404-AGENT-004")
  end

  it "non serve il bundle di un'altra organizzazione" do
    create(:agent_skill_bundle, organization: create(:organization))

    expect(described_class.call(organization:)).not_to be_ok
  end
end
