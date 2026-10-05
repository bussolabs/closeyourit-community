# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Finding, type: :model do
  it "factory valida" do
    expect(build(:vulnerability_finding)).to be_valid
  end

  it "una coppia pacchetto+advisory esiste una volta sola" do
    finding = create(:vulnerability_finding)
    duplicate = build(:vulnerability_finding, package: finding.package, advisory: finding.advisory)
    expect(duplicate).not_to be_valid
  end

  it "richiede le due date di avvistamento" do
    expect(build(:vulnerability_finding, first_seen_at: nil)).not_to be_valid
    expect(build(:vulnerability_finding, last_seen_at: nil)).not_to be_valid
  end

  it "nasce aperta" do
    expect(create(:vulnerability_finding)).to be_status_open
  end

  it "#promoted? dipende dal ticket collegato" do
    expect(build(:vulnerability_finding)).not_to be_promoted
    expect(create(:vulnerability_finding, :promoted)).to be_promoted
  end

  it "#fixable? distingue chi ha un aggiornamento da suggerire" do
    expect(build(:vulnerability_finding, fixed_version: "1.2.3")).to be_fixable
    expect(build(:vulnerability_finding, :unfixable)).not_to be_fixable
  end

  it "delega gravità e identificatore all'advisory" do
    finding = build(:vulnerability_finding, advisory: build(:vulnerability_advisory, :critical,
                                                            aliases: [ "CVE-2026-1" ]))
    expect(finding.severity).to eq("critical")
    expect(finding.display_id).to eq("CVE-2026-1")
    expect(finding).to be_promotable
  end

  it "espone le coordinate del pacchetto senza farsele chiedere in giro" do
    package = create(:vulnerability_package, name: "rails", version: "7.0.0")
    finding = create(:vulnerability_finding, package: package, project: package.manifest.project)

    expect(finding.package_name).to eq("rails")
    expect(finding.package_version).to eq("7.0.0")
    expect(finding.package_coordinates).to eq("rails@7.0.0")
  end

  describe "scope promotable" do
    it "prende solo le aperte di gravità alta o critica" do
      critical = create(:vulnerability_finding, :critical)
      high = create(:vulnerability_finding, :high)
      create(:vulnerability_finding) # moderata
      create(:vulnerability_finding, :critical, :resolved)
      create(:vulnerability_finding, :critical, :ignored)

      expect(described_class.promotable).to contain_exactly(critical, high)
    end
  end

  it "scope by_severity ordina dal più grave" do
    moderate = create(:vulnerability_finding)
    critical = create(:vulnerability_finding, :critical)
    high = create(:vulnerability_finding, :high)

    expect(described_class.by_severity.to_a).to eq([ critical, high, moderate ])
  end

  it "sparisce col progetto, non lo trattiene" do
    finding = create(:vulnerability_finding)
    expect { finding.project.destroy }.to change(described_class, :count).by(-1)
  end
end
