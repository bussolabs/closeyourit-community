# frozen_string_literal: true

require "rails_helper"

RSpec.describe Guides::Installation::Catalog do
  it "loads all nine exact implemented observations without promoting individual capabilities" do
    records = described_class.call
    expect(records.size).to eq(9)
    expect(records.map { |row| row.fetch("claim") }.uniq).to eq([ "implemented" ])
    expect(records.map { |row| row.fetch("run_id") }.uniq.size).to eq(9)
  end

  it "rejects altered snapshots and missing pinned files instead of showing an empty catalog" do
    Dir.mktmpdir do |directory|
      FileUtils.cp_r(Rails.root.join("config/installation_catalog/.").to_s, directory)
      path = Pathname(directory).join("observations.json")
      path.write(path.read.sub('"implemented"', '"verified"'))
      expect { described_class.call(directory: directory) }.to raise_error(Guides::Installation::Unavailable)
      path.delete
      expect { described_class.call(directory: directory) }.to raise_error(Guides::Installation::Unavailable)
    end
  end
  def with_catalog
    Dir.mktmpdir do |directory|
      FileUtils.cp_r(Rails.root.join("config/installation_catalog/.").to_s, directory)
      yield Pathname(directory)
    end
  end

  def replace_pinned(directory, name)
    path = directory.join(name)
    value = JSON.parse(path.read)
    yield value
    path.write(JSON.generate(value))
    lock = JSON.parse(directory.join("LOCK.json").read)
    lock["files"][name] = Digest::SHA256.file(path).hexdigest
    directory.join("LOCK.json").write(JSON.generate(lock))
  end

  it "rejects credential headers and flag/value pairs even in correctly pinned limitations" do
    [ [ "Cookie: synthetic-session" ], [ "X-Api-Key: synthetic-key" ], [ "--token", "synthetic-value" ] ].each do |limitations|
      with_catalog do |directory|
        replace_pinned(directory, "observations.json") { |snapshot| snapshot["observations"][0]["limitations"] = limitations }
        expect { described_class.call(directory: directory) }.to raise_error(Guides::Installation::Unavailable)
      end
    end
  end

  it "normalizes an invalid internal schema reference to unavailable" do
    with_catalog do |directory|
      replace_pinned(directory, "schema.json") { |schema| schema.replace({ "$ref" => "#/$defs/missing" }) }
      expect { described_class.call(directory: directory) }.to raise_error(Guides::Installation::Unavailable)
    end
  end

  it "refuses remote schema resolution without accessing the network" do
    with_catalog do |directory|
      replace_pinned(directory, "schema.json") { |schema| schema.replace({ "$ref" => "https://example.invalid/schema" }) }
      expect { described_class.call(directory: directory) }.to raise_error(Guides::Installation::Unavailable, /External/)
    end
  end

  it "preserves zero and one observations while rejecting duplicate identities and false promotions" do
    [ 0, 1 ].each do |count|
      with_catalog do |directory|
        replace_pinned(directory, "observations.json") { |snapshot| snapshot["observations"] = snapshot["observations"].first(count) }
        expect(described_class.call(directory: directory).size).to eq(count)
      end
    end
    with_catalog do |directory|
      replace_pinned(directory, "observations.json") { |snapshot| snapshot["observations"] << snapshot["observations"].first }
      expect { described_class.call(directory: directory) }.to raise_error(Guides::Installation::Unavailable)
    end
    with_catalog do |directory|
      replace_pinned(directory, "observations.json") { |snapshot| snapshot["observations"][0]["claim"] = "released" }
      expect { described_class.call(directory: directory) }.to raise_error(Guides::Installation::Unavailable)
    end
  end
end
