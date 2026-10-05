# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Channel, type: :model do
  # Gli host di test non risolvono via DNS reale → stub su IP pubblico (il guard anti-SSRF risolve).
  before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

  describe "validazioni" do
    it "webhook valido con URL https pubblica" do
      expect(build(:alerting_channel)).to be_valid
    end

    it "webhook con URL verso rete interna → invalido (anti-SSRF a config-time)" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "10.0.0.9" ])
      channel = build(:alerting_channel, config: { "url" => "https://interno.test/hook" })
      expect(channel).not_to be_valid
      expect(channel.errors[:config]).to be_present
    end

    it "webhook con URL blank → invalido" do
      expect(build(:alerting_channel, config: {})).not_to be_valid
    end

    it "webhook con schema non http(s) → invalido" do
      expect(build(:alerting_channel, config: { "url" => "ftp://x.test/hook" })).not_to be_valid
    end

    it "nome duplicato nella stessa org → invalido; stessa org, nome diverso → ok" do
      existing = create(:alerting_channel, name: "Ops")
      dup = build(:alerting_channel, organization: existing.organization, name: "Ops")
      expect(dup).not_to be_valid
      expect(build(:alerting_channel, organization: existing.organization, name: "Ops 2")).to be_valid
    end
  end

  describe "cifratura del secret (at-rest)" do
    it "webhook_secret è cifrato in colonna (ciphertext ≠ plaintext) e decifrato dal getter" do
      channel = create(:alerting_channel, webhook_secret: "super-sekret-42")
      raw = described_class.connection.select_value(
        described_class.sanitize_sql([ "SELECT webhook_secret FROM alerting_channels WHERE id = ?", channel.id ])
      )
      expect(raw).to be_present
      expect(raw).not_to include("super-sekret-42")
      expect(channel.reload.webhook_secret).to eq("super-sekret-42")
    end

    it "webhook_secret? riflette la presenza del secret" do
      expect(build(:alerting_channel, webhook_secret: "x")).to be_webhook_secret
      expect(build(:alerting_channel, webhook_secret: nil)).not_to be_webhook_secret
    end

    it "webhook valido anche senza secret (il secret è opzionale)" do
      expect(build(:alerting_channel, webhook_secret: nil)).to be_valid
    end
  end

  describe Alerting::RuleChannel do
    it "collega regola e canale della stessa org" do
      org = create(:organization)
      rule = create(:alerting_rule, organization: org)
      channel = create(:alerting_channel, organization: org)
      expect(build(:alerting_rule_channel, rule:, channel:)).to be_valid
    end

    it "rifiuta canale di un'altra org (tenant-integrity)" do
      link = build(:alerting_rule_channel, rule: create(:alerting_rule), channel: create(:alerting_channel))
      expect(link).not_to be_valid
      expect(link.errors[:channel]).to be_present
    end
  end
end
