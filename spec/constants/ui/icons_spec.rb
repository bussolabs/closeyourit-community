# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::Icons do
  describe "NAMES" do
    it "is a frozen list of Lucide icon names" do
      expect(described_class::NAMES).to be_frozen
      expect(described_class::NAMES).to include("rocket", "bug", "server", "globe")
    end

    it "only holds names Lucide can draw" do
      expect(described_class::NAMES).to all(satisfy { |name| LucideRails::IconProvider.memory.key?(name) })
    end

    it "has no duplicates" do
      expect(described_class::NAMES).to eq(described_class::NAMES.uniq)
    end
  end

  describe "FONT_AWESOME_NAMES" do
    it "turns every old Font Awesome name into one of NAMES" do
      expect(described_class::FONT_AWESOME_NAMES.values).to all(be_in(described_class::NAMES))
    end
  end

  describe ".valid?" do
    it "is true for a name in the curated set" do
      expect(described_class.valid?("rocket")).to be true
    end

    it "is false for a name outside the set" do
      expect(described_class.valid?("definitely-not-an-icon")).to be false
    end

    it "is false for nil" do
      expect(described_class.valid?(nil)).to be false
    end
  end
end
