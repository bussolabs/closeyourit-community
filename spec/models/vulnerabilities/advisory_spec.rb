# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Advisory, type: :model do
  it "factory valida" do
    expect(build(:vulnerability_advisory)).to be_valid
  end

  it "richiede osv_id univoco" do
    create(:vulnerability_advisory, osv_id: "GHSA-9822-6m93-xqf4")
    expect(build(:vulnerability_advisory, osv_id: "GHSA-9822-6m93-xqf4")).not_to be_valid
    expect(build(:vulnerability_advisory, osv_id: nil)).not_to be_valid
  end

  describe ".severity_from (scala GHSA → enum)" do
    it "mappa i valori noti, case-insensitive" do
      expect(described_class.severity_from("CRITICAL")).to eq(:critical)
      expect(described_class.severity_from("high")).to eq(:high)
      expect(described_class.severity_from("Moderate")).to eq(:moderate)
      expect(described_class.severity_from("MEDIUM")).to eq(:moderate)
      expect(described_class.severity_from("LOW")).to eq(:low)
    end

    it "tutto ciò che non riconosce resta unknown" do
      expect(described_class.severity_from(nil)).to eq(:unknown)
      expect(described_class.severity_from("")).to eq(:unknown)
      expect(described_class.severity_from("SEVERE")).to eq(:unknown)
    end
  end

  describe "#promotable? (gate del ticket automatico)" do
    it "solo alta e critica" do
      expect(build(:vulnerability_advisory, :critical)).to be_promotable
      expect(build(:vulnerability_advisory, :high)).to be_promotable
    end

    it "moderata, bassa e SOPRATTUTTO sconosciuta non promuovono" do
      expect(build(:vulnerability_advisory, severity: :moderate)).not_to be_promotable
      expect(build(:vulnerability_advisory, :low)).not_to be_promotable
      expect(build(:vulnerability_advisory, :unknown_severity)).not_to be_promotable
    end
  end

  it "scope promotable seleziona le stesse di promotable?" do
    critical = create(:vulnerability_advisory, :critical)
    high = create(:vulnerability_advisory, :high)
    create(:vulnerability_advisory, severity: :moderate)
    create(:vulnerability_advisory, :unknown_severity)

    expect(described_class.promotable).to contain_exactly(critical, high)
  end

  describe "#display_id" do
    it "preferisce il CVE, che è l'identificatore con cui la gente cerca" do
      advisory = build(:vulnerability_advisory, osv_id: "GHSA-x", aliases: %w[BIT-rails-1 CVE-2024-26143])
      expect(advisory.display_id).to eq("CVE-2024-26143")
    end

    it "ripiega sull'id OSV se non c'è un CVE" do
      expect(build(:vulnerability_advisory, :without_cve, osv_id: "GHSA-x").display_id).to eq("GHSA-x")
    end
  end

  it "#osv_url deriva dall'id quando l'url non è dichiarato" do
    expect(build(:vulnerability_advisory, osv_id: "GHSA-x", url: nil).osv_url)
      .to eq("https://osv.dev/vulnerability/GHSA-x")
    expect(build(:vulnerability_advisory, url: "https://example.test/a").osv_url)
      .to eq("https://example.test/a")
  end
end
