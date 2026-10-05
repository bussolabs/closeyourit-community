# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Osv::Query do
  let(:client) { instance_double(Vulnerabilities::Osv::Client) }
  let(:rails_coordinate) { [ "RubyGems", "rails", "7.0.0" ] }
  let(:lodash_coordinate) { [ "npm", "lodash", "4.17.15" ] }

  def record(id, severity: "HIGH", name: "rails", ecosystem: "RubyGems")
    {
      "id" => id,
      "aliases" => [ "CVE-2024-1" ],
      "summary" => "Falla",
      "database_specific" => { "severity" => severity },
      "affected" => [ { "package" => { "name" => name, "ecosystem" => ecosystem },
                        "ranges" => [ { "events" => [ { "introduced" => "0" }, { "fixed" => "7.0.8.1" } ] } ] } ],
      "published" => "2024-02-27T16:15:46Z",
      "modified" => "2026-06-08T23:45:17Z"
    }
  end

  it "nessuna coordinata: nessuna richiesta, mappa vuota" do
    expect(client).not_to receive(:query_batch)
    expect(described_class.call(coordinates: [], client: client)).to eq({})
  end

  it "collega ogni coordinata agli advisory che la colpiscono" do
    allow(client).to receive(:query_batch).and_return([ [ "GHSA-1" ], [] ])
    allow(client).to receive(:vulnerability).with("GHSA-1").and_return(record("GHSA-1"))

    result = described_class.call(coordinates: [ rails_coordinate, lodash_coordinate ], client: client)

    expect(result.keys).to eq([ rails_coordinate ])
    expect(result[rails_coordinate].map(&:osv_id)).to eq([ "GHSA-1" ])
  end

  it "crea l'advisory con gravità, alias e affected pronti per l'uso" do
    allow(client).to receive(:query_batch).and_return([ [ "GHSA-1" ] ])
    allow(client).to receive(:vulnerability).and_return(record("GHSA-1"))

    described_class.call(coordinates: [ rails_coordinate ], client: client)
    advisory = Vulnerabilities::Advisory.find_by(osv_id: "GHSA-1")

    expect(advisory).to be_severity_high
    expect(advisory.aliases).to eq([ "CVE-2024-1" ])
    expect(advisory.fixed_version_for(ecosystem: "RubyGems", name: "rails", version: "7.0.0"))
      .to eq("7.0.8.1")
  end

  it "un advisory già noto e fresco non viene riscaricato" do
    existing = create(:vulnerability_advisory, osv_id: "GHSA-1", refreshed_at: 1.hour.ago)
    allow(client).to receive(:query_batch).and_return([ [ "GHSA-1" ] ])
    expect(client).not_to receive(:vulnerability)

    result = described_class.call(coordinates: [ rails_coordinate ], client: client)

    expect(result[rails_coordinate]).to eq([ existing ])
  end

  it "un advisory vecchio viene riletto: la gravità può essere stata alzata" do
    stale = create(:vulnerability_advisory, osv_id: "GHSA-1", severity: :low,
                                            refreshed_at: 30.days.ago)
    allow(client).to receive(:query_batch).and_return([ [ "GHSA-1" ] ])
    allow(client).to receive(:vulnerability).with("GHSA-1").and_return(record("GHSA-1", severity: "CRITICAL"))

    described_class.call(coordinates: [ rails_coordinate ], client: client)

    expect(stale.reload).to be_severity_critical
  end

  it "lo stesso advisory su più coordinate si scarica una volta sola" do
    allow(client).to receive(:query_batch).and_return([ [ "GHSA-1" ], [ "GHSA-1" ] ])
    allow(client).to receive(:vulnerability).with("GHSA-1").once.and_return(record("GHSA-1"))

    result = described_class.call(coordinates: [ rails_coordinate, lodash_coordinate ], client: client)

    expect(result.size).to eq(2)
    expect(Vulnerabilities::Advisory.where(osv_id: "GHSA-1").count).to eq(1)
  end

  it "un advisory ritirato dopo il batch non fa saltare la scansione" do
    allow(client).to receive(:query_batch).and_return([ %w[GHSA-1 GHSA-sparito] ])
    allow(client).to receive(:vulnerability).with("GHSA-1").and_return(record("GHSA-1"))
    allow(client).to receive(:vulnerability).with("GHSA-sparito").and_return(nil)

    result = described_class.call(coordinates: [ rails_coordinate ], client: client)

    expect(result[rails_coordinate].map(&:osv_id)).to eq([ "GHSA-1" ])
  end

  it "spezza le coordinate in lotti invece di spedirne migliaia in una richiesta" do
    stub_const("Vulnerabilities::Constants::OSV_BATCH_SIZE", 2)
    coordinates = Array.new(5) { |i| [ "npm", "pkg-#{i}", "1.0.0" ] }
    allow(client).to receive(:query_batch).and_return([ [], [] ], [ [], [] ], [ [] ])

    described_class.call(coordinates: coordinates, client: client)

    expect(client).to have_received(:query_batch).exactly(3).times
  end

  it "le coordinate ripetute si interrogano una volta sola" do
    allow(client).to receive(:query_batch).and_return([ [] ])

    described_class.call(coordinates: [ rails_coordinate, rails_coordinate ], client: client)

    expect(client).to have_received(:query_batch).with([ hash_including(name: "rails") ])
  end
end
