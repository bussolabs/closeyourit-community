# frozen_string_literal: true

require "rails_helper"

# CYAU-235 — the supporter decides alone only up to 6, and a score never goes down.
RSpec.describe Agents::Supporters::RiskScore do
  describe ".resolve" do
    it "keeps a valid proposed score when nothing raises it" do
      expect(described_class.resolve(previous: nil, proposed: 3)).to eq(3)
    end

    it "never goes below an earlier score" do
      expect(described_class.resolve(previous: 7, proposed: 2)).to eq(7)
    end

    it "treats a missing or unreadable score as the highest risk" do
      expect(described_class.resolve(previous: nil, proposed: nil)).to eq(10)
      expect(described_class.resolve(previous: nil, proposed: 0)).to eq(10)
      expect(described_class.resolve(previous: nil, proposed: 11)).to eq(10)
      expect(described_class.resolve(previous: nil, proposed: "4")).to eq(10)
    end

    it "raises to 10 on any reserved topic" do
      expect(described_class.resolve(previous: nil, proposed: 2, reserved: true)).to eq(10)
    end

    it "raises to at least 8 when a sensitive path is touched" do
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ "db/migrate/20261006_add_x.rb" ])).to eq(8)
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ ".github/workflows/ci.yml" ])).to eq(8)
      expect(described_class.resolve(previous: nil, proposed: 9, paths: [ "config/deploy.yml" ])).to eq(9)
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ "app/controllers/auth/sessions_controller.rb" ])).to eq(8)
    end

    it "leaves ordinary code paths alone" do
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ "src/price.js", "test/price.test.js" ])).to eq(2)
    end
  end

  describe ".autonomous?" do
    it "lets the supporter decide alone only from 1 to 6" do
      expect((1..10).select { |score| described_class.autonomous?(score) }).to eq([ 1, 2, 3, 4, 5, 6 ])
      expect(described_class.autonomous?(nil)).to be(false)
    end
  end

  describe ".risk_level" do
    it "maps the score onto the plan risk levels" do
      expect([ 1, 3, 4, 6, 7, 10 ].map { |score| described_class.risk_level(score) })
        .to eq(%w[low low medium medium high high])
    end
  end
end
