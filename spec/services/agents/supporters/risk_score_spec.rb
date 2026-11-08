# frozen_string_literal: true

require "rails_helper"

# CYAU-235 — the supporter decides alone only up to 8, and a score never goes down.
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

    it "raises to at least 9 when a guarded path is touched, above what the supporter decides alone" do
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ ".github/workflows/ci.yml" ])).to eq(9)
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ ".kamal/secrets" ])).to eq(9)
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ "config/credentials.yml.enc" ])).to eq(9)
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ "app/controllers/auth/sessions_controller.rb" ])).to eq(9)
    end

    # CYRA-1197 — database, deploy and release files: the supporter judges the content, the score stays in its range.
    it "raises to 7 on database, deploy and release paths, which the supporter may still decide" do
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ "db/migrate/20261006_add_x.rb" ])).to eq(7)
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ "config/deploy.yml" ])).to eq(7)
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ "scripts/release/tag.sh" ])).to eq(7)
      expect(described_class.resolve(previous: nil, proposed: 10, paths: [ "config/deploy.yml" ])).to eq(10)
    end

    it "leaves ordinary code paths alone" do
      expect(described_class.resolve(previous: nil, proposed: 2, paths: [ "src/price.js", "test/price.test.js" ])).to eq(2)
    end
  end

  describe ".autonomous?" do
    it "lets the supporter decide alone only from 1 to 8" do
      expect((1..10).select { |score| described_class.autonomous?(score) }).to eq([ 1, 2, 3, 4, 5, 6, 7, 8 ])
      expect(described_class.autonomous?(nil)).to be(false)
    end
  end

  describe ".risk_level" do
    it "maps the score onto the plan risk levels" do
      expect([ 1, 3, 4, 8, 9, 10 ].map { |score| described_class.risk_level(score) })
        .to eq(%w[low low medium medium high high])
    end
  end
end
