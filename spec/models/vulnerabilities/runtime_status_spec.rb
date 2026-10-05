# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::RuntimeStatus, type: :model do
  it "factory valida" do
    expect(build(:vulnerability_runtime_status)).to be_valid
  end

  it "un runtime compare una sola volta per progetto" do
    status = create(:vulnerability_runtime_status, name: "ruby")
    expect(build(:vulnerability_runtime_status, project: status.project, name: "ruby")).not_to be_valid
    expect(build(:vulnerability_runtime_status, project: status.project, name: "nodejs")).to be_valid
  end

  it "richiede nome e versione" do
    expect(build(:vulnerability_runtime_status, name: nil)).not_to be_valid
    expect(build(:vulnerability_runtime_status, version: nil)).not_to be_valid
  end

  describe ".state_for" do
    let(:today) { Date.new(2026, 8, 10) }

    it "scaduta ieri o oggi è fuori supporto" do
      expect(described_class.state_for(today - 1, today)).to eq(:eol)
      expect(described_class.state_for(today, today)).to eq(:eol)
    end

    it "entro la finestra di preavviso avvisa prima della scadenza" do
      expect(described_class.state_for(today + 30, today)).to eq(:ending_soon)
      expect(described_class.state_for(today + Vulnerabilities::Constants::RUNTIME_EOL_WARNING_DAYS, today))
        .to eq(:ending_soon)
    end

    it "oltre la finestra è supportata" do
      expect(described_class.state_for(today + Vulnerabilities::Constants::RUNTIME_EOL_WARNING_DAYS + 1, today))
        .to eq(:supported)
    end

    it "senza data non inventa un allarme" do
      expect(described_class.state_for(nil, today)).to eq(:supported)
    end
  end

  it "#days_to_eol conta i giorni residui, nil senza data" do
    travel_to(Time.zone.local(2026, 8, 10)) do
      expect(build(:vulnerability_runtime_status, eol_on: Date.new(2026, 8, 20)).days_to_eol).to eq(10)
      expect(build(:vulnerability_runtime_status, :undated).days_to_eol).to be_nil
    end
  end

  it "#outdated? confronta con l'ultima versione pubblicata" do
    expect(build(:vulnerability_runtime_status, version: "3.4.2", latest: "3.4.10")).to be_outdated
    expect(build(:vulnerability_runtime_status, version: "3.4.10", latest: "3.4.10")).not_to be_outdated
    expect(build(:vulnerability_runtime_status, :undated)).not_to be_outdated
  end

  it "scope attention prende chi va guardato adesso" do
    eol = create(:vulnerability_runtime_status, :eol, name: "ruby")
    soon = create(:vulnerability_runtime_status, :ending_soon, name: "nodejs", project: eol.project)
    create(:vulnerability_runtime_status, name: "flutter", project: eol.project)

    expect(described_class.attention).to contain_exactly(eol, soon)
  end
end
