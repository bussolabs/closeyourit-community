# frozen_string_literal: true

require "rails_helper"

RSpec.describe Guides::Installation::Catalog, "evidence trust boundaries" do
  def with_catalog
    Dir.mktmpdir("catalog-boundaries-") do |directory|
      FileUtils.cp_r(Rails.root.join("config/installation_catalog/.").to_s, directory)
      yield Pathname(directory)
    end
  end

  it "rejects duplicate lock keys, excessive lock bytes and symlinked files" do
    with_catalog do |directory|
      lock = directory.join("LOCK.json")
      files = JSON.generate(JSON.parse(lock.read).fetch("files"))
      lock.write("{\"files\":#{files},\"files\":#{files}}")
      expect { described_class.call(directory: directory) }.to raise_error(Guides::Installation::Unavailable)
      lock.write(" " * 4097)
      expect { described_class.call(directory: directory) }.to raise_error(Guides::Installation::Unavailable, /byte budget/)
      lock.delete
      File.symlink(Rails.root.join("config/installation_catalog/LOCK.json"), lock)
      expect { described_class.call(directory: directory) }.to raise_error(Guides::Installation::Unavailable, /regular file/)
    end
  end

  it "allows redacted or absent values but rejects a flag with an unredacted argument" do
    catalog = described_class.new
    [ { "token" => nil }, { "token" => "" }, { "token" => "[REDACTED]" }, [ "--password", "[REDACTED]" ], [ "--token" ], false ].each do |value|
      expect(catalog.send(:secret?, value)).to be(false)
    end
    expect(catalog.send(:secret?, [ "--password", "test-only-rejected-value" ])).to be(true)
    expect(catalog.send(:secret?, { "client.secret" => "test-only-rejected-value" })).to be(true)
  end

  it "rejects a promoted error-only record even if its code is clean" do
    row = JSON.parse(described_class.call.find { |entry| entry["profile"] == "sentry-errors-v1" }.to_json)
    row["claim"] = "verified"
    row["tuple"]["backend"]["dirty"] = false
    expect { described_class.new.send(:validate_claim!, row) }.to raise_error(Guides::Installation::Unavailable, /Error-only/)
  end

  it "requires clean complete evidence before a verified claim and a registry before a release claim" do
    row = JSON.parse(described_class.call.find { |entry| entry["profile"] == "general-v1" }.to_json)
    row["claim"] = "verified"
    expect { described_class.new.send(:validate_claim!, row) }.to raise_error(Guides::Installation::Unavailable, /Incomplete/)
    row["tuple"]["backend"]["dirty"] = false
    row["capabilities"].each { |cap| cap["status"] = "pass" }
    expect { described_class.new.send(:validate_claim!, row) }.not_to raise_error
    row["capabilities"].first.merge!("required" => true, "status" => "fail")
    expect { described_class.new.send(:validate_claim!, row) }.to raise_error(Guides::Installation::Unavailable, /Incomplete/)
    row["capabilities"].first["status"] = "pass"
    row["claim"] = "released"
    expect { described_class.new.send(:validate_claim!, row) }.to raise_error(Guides::Installation::Unavailable, /Local/)
  end
end
