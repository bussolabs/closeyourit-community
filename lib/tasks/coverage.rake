# frozen_string_literal: true

require "coverage_resultset_normalizer"

namespace :coverage do
  desc "Collaziona la coverage prodotta dagli shard CI"
  task :collate do
    require "simplecov"
    require "simplecov_configuration"

    expected_shards = Integer(ENV.fetch("TEST_SHARDS", "4"), 10)
    resultsets = Dir["coverage-results/shard-*/.resultset.json"].sort
    abort "Attesi #{expected_shards} resultset, trovati #{resultsets.size}" unless resultsets.size == expected_shards

    normalized = resultsets.map do |resultset|
      workspace_file = Pathname(resultset).dirname.join("workspace.txt")
      abort "Workspace metadata assente per #{resultset}" unless workspace_file.file?

      CoverageResultsetNormalizer.call(
        resultset:,
        source_root: workspace_file.read.strip,
        destination_root: Dir.pwd
      ).to_s
    end

    SimplecovConfiguration.apply
    SimpleCov.merge_timeout 3600
    SimpleCov.collate(normalized, "rails")
  end
end
