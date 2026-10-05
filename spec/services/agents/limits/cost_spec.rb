# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Limits::Cost do
  describe ".parse" do
    it "mantiene distinti costo sconosciuto e zero" do
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse(0)).to eq(BigDecimal("0"))
    end

    it "accetta la scala canonica e il massimo numeric(14,4)" do
      expect(described_class.parse("0.5000")).to eq(BigDecimal("0.5"))
      expect(described_class.parse("9999999999.9999")).to eq(BigDecimal("9999999999.9999"))
    end

    it "rifiuta precisione e magnitudine non rappresentabili" do
      expect(described_class.parse("0.00001")).to be_nil
      expect(described_class.parse("10000000000")).to be_nil
    end

    it "rifiuta valori negativi, non numerici e non finiti" do
      expect(described_class.parse(-1)).to be_nil
      expect(described_class.parse("costo")).to be_nil
      expect(described_class.parse("Infinity")).to be_nil
    end
  end
end
