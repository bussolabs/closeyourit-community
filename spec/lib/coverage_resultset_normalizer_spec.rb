# frozen_string_literal: true

require "spec_helper"
require "coverage_resultset_normalizer"
require "tmpdir"

RSpec.describe CoverageResultsetNormalizer do
  it "normalizza soltanto i file appartenenti al workspace dello shard" do
    Dir.mktmpdir do |directory|
      resultset = Pathname(directory).join(".resultset.json")
      resultset.write(JSON.generate(
        "rspec-shard-1" => {
          "coverage" => {
            "/runner-1/project/app/models/account.rb" => { "lines" => [ 1, 0 ] },
            "/external/gem.rb" => { "lines" => [ 1 ] }
          },
          "timestamp" => 1_700_000_000
        }
      ))

      normalized = described_class.call(
        resultset:,
        source_root: "/runner-1/project",
        destination_root: "/merge/project"
      )

      coverage = JSON.parse(normalized.read).fetch("rspec-shard-1").fetch("coverage")
      expect(coverage).to include(
        "/merge/project/app/models/account.rb" => { "lines" => [ 1, 0 ] },
        "/external/gem.rb" => { "lines" => [ 1 ] }
      )
    end
  end

  it "rifiuta metadati workspace vuoti" do
    expect {
      described_class.call(resultset: __FILE__, source_root: "", destination_root: "/merge/project")
    }.to raise_error(ArgumentError, "source_root non può essere vuoto")
  end
end
