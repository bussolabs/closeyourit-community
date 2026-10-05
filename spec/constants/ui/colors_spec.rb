# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::Colors do
  # 16 colori: gli 8 storici + gli 8 aggiunti in CYRA-69 (blue/cyan/green/lime/orange/red/fuchsia/pink).
  EXPECTED_COLORS = %w[
    indigo emerald violet amber teal sky rose gray
    blue cyan green lime orange red fuchsia pink
  ].freeze

  describe "SWATCH" do
    it "espone esattamente i 16 colori attesi" do
      expect(described_class::SWATCH.keys).to match_array(EXPECTED_COLORS)
      expect(described_class::SWATCH.size).to eq(16)
    end

    it "usa classi Tailwind letterali coerenti con la chiave (mai interpolate)" do
      described_class::SWATCH.each do |color, klass|
        expect(klass).to start_with("bg-#{color}-")
        expect(klass).to match(/\Abg-\S+-\d{3}\z/)
      end
    end

    it "espone SWATCH_COLORS allineato alle chiavi di SWATCH" do
      expect(described_class::SWATCH_COLORS).to eq(described_class::SWATCH.keys)
    end
  end

  def light_classes(klass) = klass.split.reject { |token| token.start_with?("dark:") }.join(" ")

  describe "CHIP" do
    it "è gemella di SWATCH: stesse chiavi nello stesso ordine" do
      expect(described_class::CHIP.keys).to eq(described_class::SWATCH.keys)
    end

    # The dark look adds `dark:` twins next to the light classes; the light pair stays the contract.
    it "usa classi tint letterali coerenti con la chiave (bg-{c}-50 text-{c}-600)" do
      described_class::CHIP.each do |color, klass|
        expect(light_classes(klass)).to eq("bg-#{color}-50 text-#{color}-600")
      end
    end
  end

  describe "label i18n" do
    it "ha una traduzione it e en per ogni colore della palette" do
      described_class::SWATCH_COLORS.each do |color|
        expect { I18n.t("ui.colors.#{color}", locale: :it, raise: true) }.not_to raise_error
        expect { I18n.t("ui.colors.#{color}", locale: :en, raise: true) }.not_to raise_error
      end
    end

    it "non ha label duplicate entro la stessa lingua" do
      %i[it en].each do |locale|
        labels = described_class::SWATCH_COLORS.map { |c| I18n.t("ui.colors.#{c}", locale:) }
        expect(labels.uniq.size).to eq(labels.size), "label duplicate in #{locale}: #{labels}"
      end
    end
  end

  describe ".swatch" do
    it "ritorna la classe letterale per ognuno dei 16 colori" do
      EXPECTED_COLORS.each do |color|
        expect(described_class.swatch(color)).to start_with("bg-#{color}-")
      end
    end

    it "ritorna il default per un colore sconosciuto" do
      expect(described_class.swatch("not-a-color")).to eq(described_class::SWATCH_DEFAULT)
    end
  end

  describe ".chip" do
    it "ritorna le classi tint (bg + text) letterali per un colore noto" do
      expect(light_classes(described_class.chip("indigo"))).to eq("bg-indigo-50 text-indigo-600")
      expect(light_classes(described_class.chip("emerald"))).to eq("bg-emerald-50 text-emerald-600")
    end

    it "copre tutti gli swatch disponibili" do
      Ui::Colors::SWATCH_COLORS.each do |color|
        expect(light_classes(described_class.chip(color))).to match(/\Abg-\S+-50 text-\S+-600\z/)
      end
    end

    it "ritorna il default per un colore sconosciuto" do
      expect(described_class.chip("not-a-color")).to eq(described_class::CHIP_DEFAULT)
    end

    it "ritorna il default per nil" do
      expect(described_class.chip(nil)).to eq(described_class::CHIP_DEFAULT)
    end
  end
end
