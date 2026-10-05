# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Token, type: :model do
  it "è valido con gli attributi della factory" do
    expect(build(:agent_token)).to be_valid
  end

  it "richiede name, token_prefix, token_digest" do
    token = build(:agent_token, name: "", token_prefix: "", token_digest: "")
    expect(token).to be_invalid
    expect(token.errors.attribute_names).to include(:name, :token_prefix, :token_digest)
  end

  it "impone name unico per org e token_digest globalmente unico" do
    existing = create(:agent_token, name: "automator")
    expect(build(:agent_token, name: "automator", organization: existing.organization)).to be_invalid
    expect(build(:agent_token, token_digest: existing.token_digest)).to be_invalid
  end

  describe ".active" do
    it "esclude i revocati" do
      live = create(:agent_token)
      dead = create(:agent_token, :revoked)
      expect(described_class.active).to include(live)
      expect(described_class.active).not_to include(dead)
    end
  end

  describe "#revoked?" do
    it { expect(build(:agent_token).revoked?).to be(false) }
    it { expect(build(:agent_token, :revoked).revoked?).to be(true) }
  end

  describe "#stale_usage?" do
    it "è vero se mai usato o usato oltre la soglia" do
      expect(build(:agent_token, last_used_at: nil).stale_usage?).to be(true)
      expect(build(:agent_token, last_used_at: 2.minutes.ago).stale_usage?).to be(true)
    end

    it "è falso se usato di recente" do
      expect(build(:agent_token, last_used_at: 1.second.ago).stale_usage?).to be(false)
    end
  end
end
