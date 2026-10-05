# frozen_string_literal: true

require "rails_helper"

RSpec.describe Monitoring::Tool, type: :model do
  describe ".codes / .all / .known?" do
    it "espone i code del registry" do
      expect(described_class.codes).to include("closeyourit-ruby", "closeyourit-js", "closeyourit-dart")
    end

    it "known? è vero solo per i tool del registry" do
      expect(described_class.known?("closeyourit-ruby")).to be(true)
      expect(described_class.known?("sconosciuto")).to be(false)
    end

    it "all ritorna un Tool per ogni code" do
      expect(described_class.all.map(&:code)).to eq(described_class.codes)
    end
  end

  describe ".find" do
    it "ritorna il Tool per un code noto" do
      expect(described_class.find("closeyourit-ruby").code).to eq("closeyourit-ruby")
    end

    it "ritorna nil per un code ignoto" do
      expect(described_class.find("sconosciuto")).to be_nil
    end
  end

  describe "attributi struttura" do
    it "icona e colore dal registry per un tool noto" do
      tool = described_class.new("closeyourit-ruby")
      expect(tool.icon).to eq("gem")
      expect(tool.color).to eq("rose")
    end

    it "fallback icona/colore per un tool ignoto" do
      tool = described_class.new("sconosciuto")
      expect(tool.icon).to eq(described_class::FALLBACK_ICON)
      expect(tool.color).to eq(described_class::FALLBACK_COLOR)
      expect(tool.known?).to be(false)
    end

    it "platform_codes come hint per il picker atteso" do
      expect(described_class.new("closeyourit-dart").platform_codes).to eq(%w[ios android])
      expect(described_class.new("closeyourit-agent").platform_codes).to eq([])
    end
  end

  describe "label i18n" do
    it "usa la chiave i18n del code" do
      expect(described_class.new("closeyourit-ruby").label).to eq(
        I18n.t("monitoring.tools.closeyourit-ruby.label")
      )
    end

    it "default = code per un tool senza traduzione" do
      expect(described_class.new("sconosciuto").label).to eq("sconosciuto")
    end
  end

  describe "uguaglianza per code" do
    it "due Tool con lo stesso code sono uguali e hanno lo stesso hash" do
      a = described_class.new("closeyourit-ruby")
      b = described_class.new("closeyourit-ruby")
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "code diversi non sono uguali" do
      expect(described_class.new("closeyourit-ruby")).not_to eq(described_class.new("closeyourit-js"))
    end
  end
end
