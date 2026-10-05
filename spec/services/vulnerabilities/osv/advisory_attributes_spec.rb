# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Osv::AdvisoryAttributes do
  # Risposta REALE di OSV.dev per GHSA-9822-6m93-xqf4 (XSS in Action Controller), scaricata e
  # congelata: è il contratto che stiamo traducendo, non una nostra idea di come sia fatto.
  let(:record) { JSON.parse(Rails.root.join("spec/fixtures/vulnerabilities/osv_vuln.json").read) }

  subject(:attributes) { described_class.call(record: record, now: Time.zone.local(2026, 8, 10)) }

  it "porta dentro gli alias, da cui si ricava il CVE" do
    expect(attributes[:aliases]).to include("CVE-2024-26143")
  end

  it "legge la gravità dalla scala GHSA, non dal punteggio CVSS" do
    expect(attributes[:severity]).to eq(:moderate)
    expect(attributes[:cvss]).to start_with("CVSS:")
  end

  it "conserva i CWE" do
    expect(attributes[:cwe_ids]).to include("CWE-79")
  end

  it "riduce affected a package + ranges, buttando il resto" do
    affected = attributes[:affected]
    expect(affected.map { |entry| entry.dig("package", "name") }).to include("actionpack", "rails")
    expect(affected.first.keys).to contain_exactly("package", "ranges")
    expect(affected.first["ranges"].first["events"]).to be_an(Array)
  end

  it "converte le date e marca il momento della lettura" do
    expect(attributes[:published_at]).to be_a(ActiveSupport::TimeWithZone)
    expect(attributes[:modified_at]).to be_a(ActiveSupport::TimeWithZone)
    expect(attributes[:refreshed_at]).to eq(Time.zone.local(2026, 8, 10))
  end

  it "un record vuoto non esplode: dà attributi neutri con gravità sconosciuta" do
    result = described_class.call(record: {})

    expect(result[:severity]).to eq(:unknown)
    expect(result[:aliases]).to eq([])
    expect(result[:affected]).to eq([])
    expect(result[:published_at]).to be_nil
  end

  it "una data illeggibile diventa nil invece di far fallire la scansione" do
    result = described_class.call(record: { "published" => "non-una-data" })
    expect(result[:published_at]).to be_nil
  end
end
