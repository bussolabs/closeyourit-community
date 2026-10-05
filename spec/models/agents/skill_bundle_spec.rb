# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::SkillBundle, type: :model do
  it "è valido con la factory" do
    expect(build(:agent_skill_bundle)).to be_valid
  end

  it "richiede un'organizzazione" do
    expect(build(:agent_skill_bundle, organization: nil)).not_to be_valid
  end

  describe "repo" do
    it "accetta owner/name e rifiuta un valore senza slash" do
      expect(build(:agent_skill_bundle, repo: "owner/name")).to be_valid
      expect(build(:agent_skill_bundle, repo: "senza-slash")).not_to be_valid
    end
  end

  describe "ref/version/digest" do
    it "sono obbligatori" do
      expect(build(:agent_skill_bundle, ref: "")).not_to be_valid
      expect(build(:agent_skill_bundle, version: "")).not_to be_valid
      expect(build(:agent_skill_bundle, digest: "")).not_to be_valid
    end

    it "version rifiuta separatori e traversal (finisce come segmento di path)" do
      expect(build(:agent_skill_bundle, version: "a/b")).not_to be_valid
      expect(build(:agent_skill_bundle, version: "..")).not_to be_valid
      expect(build(:agent_skill_bundle, version: "0.1.0")).to be_valid
    end

    it "digest deve essere esadecimale (7..64)" do
      expect(build(:agent_skill_bundle, digest: "ZZZ")).not_to be_valid
      expect(build(:agent_skill_bundle, digest: "abc")).not_to be_valid # troppo corto
      expect(build(:agent_skill_bundle, digest: "abcdef1234")).to be_valid
    end
  end

  it "è singleton per organizzazione" do
    org = create(:organization)
    create(:agent_skill_bundle, organization: org)
    expect(build(:agent_skill_bundle, organization: org)).not_to be_valid
  end

  it "normalizza digest in minuscolo e trimma repo/ref/version" do
    bundle = create(:agent_skill_bundle, digest: "  ABCDEF1234  ", repo: " owner/name ", ref: " v1 ", version: " 1.0.0 ")
    expect(bundle.digest).to eq("abcdef1234")
    expect(bundle.repo).to eq("owner/name")
    expect(bundle.ref).to eq("v1")
    expect(bundle.version).to eq("1.0.0")
  end
end
