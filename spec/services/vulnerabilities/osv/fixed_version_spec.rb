# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Osv::FixedVersion do
  def affected_for(name, ecosystem: "RubyGems", events:)
    [ { "package" => { "name" => name, "ecosystem" => ecosystem },
        "ranges" => [ { "events" => events } ] } ]
  end

  it "prende la prima versione che risolve sopra a quella installata" do
    affected = affected_for("actionpack", events: [ { "introduced" => "7.0.0" }, { "fixed" => "7.0.8.1" } ])

    result = described_class.call(affected: affected, ecosystem: "RubyGems",
                                  name: "actionpack", version: "7.0.0")
    expect(result).to eq("7.0.8.1")
  end

  it "sceglie il fix MINIMO fra più intervalli, non l'ultimo" do
    affected = affected_for("rails", events: [
                              { "introduced" => "6.0.0" }, { "fixed" => "6.1.7.6" },
                              { "introduced" => "7.0.0" }, { "fixed" => "7.0.8.1" }
                            ])

    result = described_class.call(affected: affected, ecosystem: "RubyGems", name: "rails",
                                  version: "6.0.1")
    expect(result).to eq("6.1.7.6")
  end

  it "ignora le voci di un altro pacchetto dello stesso advisory" do
    affected = affected_for("actionpack", events: [ { "fixed" => "7.0.8.1" } ]) +
               affected_for("rails", events: [ { "fixed" => "9.9.9" } ])

    result = described_class.call(affected: affected, ecosystem: "RubyGems",
                                  name: "actionpack", version: "7.0.0")
    expect(result).to eq("7.0.8.1")
  end

  it "ignora le voci di un altro ecosistema con lo stesso nome" do
    affected = affected_for("http", ecosystem: "npm", events: [ { "fixed" => "1.0.0" } ])

    result = described_class.call(affected: affected, ecosystem: "Pub", name: "http", version: "0.13.0")
    expect(result).to be_nil
  end

  it "nessun fix dichiarato → nil, e la sezione lo dirà invece di inventare un numero" do
    affected = affected_for("foo", events: [ { "introduced" => "0" } ])

    expect(described_class.call(affected: affected, ecosystem: "RubyGems", name: "foo", version: "1.0"))
      .to be_nil
  end

  it "affected assente o vuoto → nil" do
    expect(described_class.call(affected: nil, ecosystem: "RubyGems", name: "foo", version: "1.0")).to be_nil
    expect(described_class.call(affected: [], ecosystem: "RubyGems", name: "foo", version: "1.0")).to be_nil
  end

  it "versioni non confrontabili: ripiega sul fix dichiarato invece di tacere" do
    affected = affected_for("mod", ecosystem: "Go",
                            events: [ { "fixed" => "0.0.0-20220715151400-c0bba94af5f8" } ])

    result = described_class.call(affected: affected, ecosystem: "Go", name: "mod",
                                  version: "0.0.0-20210101000000-aaaaaaaaaaaa")
    expect(result).to eq("0.0.0-20220715151400-c0bba94af5f8")
  end

  it "accetta anche affected con chiavi simboliche (round-trip jsonb)" do
    affected = [ { package: { name: "rails", ecosystem: "RubyGems" },
                   ranges: [ { events: [ { fixed: "7.0.8.1" } ] } ] } ]

    expect(described_class.call(affected: affected, ecosystem: "RubyGems", name: "rails", version: "7.0.0"))
      .to eq("7.0.8.1")
  end
end
