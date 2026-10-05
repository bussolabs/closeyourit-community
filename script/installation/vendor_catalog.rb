#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "pathname"
require "open3"
require "tempfile"
require "tmpdir"

abort "Usage: bundle exec ruby script/installation/vendor_catalog.rb /absolute/closeyourit-docs" unless ARGV.one? && Pathname(ARGV.first).absolute?
source = Pathname(ARGV.first).realpath
catalog_path = "compatibility/catalog/observations.json"
schema_path = "contracts/certification/v1/schema.json"
commit, status = Open3.capture2("git", "-C", source.to_s, "rev-parse", "HEAD")
abort "Source must be a committed repository" unless status.success?
inputs = [ catalog_path, schema_path, "scripts/build_integration_catalog.py", "scripts/verify_certification_contract.py" ]
dirty, status = Open3.capture2("git", "-C", source.to_s, "status", "--porcelain", "--", *inputs)
abort "Catalog source inputs must be committed" unless status.success? && dirty.empty?
raw = source.join(catalog_path).binread
abort "Catalog is too large" if raw.bytesize > 5 * 1024 * 1024
source_schema = JSON.parse(source.join(schema_path).read)
fields = %w[run_id profile finished_at claim tuple capabilities limitations]
properties = source_schema.fetch("properties").slice(*fields).merge(
  "manifest_sha256" => { "type" => "string", "pattern" => "^[a-f0-9]{64}$" },
  "ticket" => { "type" => "string", "pattern" => "^CYRA-[1-9][0-9]*$" })
schema = { "type" => "object", "additionalProperties" => false, "required" => %w[schema_version observations],
  "$defs" => source_schema.fetch("$defs"), "properties" => { "schema_version" => { "const" => 1 },
  "observations" => { "type" => "array", "maxItems" => 10_000, "items" => { "type" => "object",
    "additionalProperties" => false, "required" => properties.keys, "properties" => properties } } } }
payloads = { "observations.json" => raw, "schema.json" => JSON.pretty_generate(schema) + "\n" }
payloads["LOCK.json"] = JSON.pretty_generate({ source_repository: "bussolabs/closeyourit-docs", source_commit: commit.strip,
  files: payloads.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } }) + "\n"
root = Pathname(__dir__).join("../..").realpath
require root.join("config/environment")
Dir.mktmpdir do |staging|
  payloads.each { |name, bytes| File.binwrite(File.join(staging, name), bytes) }
  Guides::Installation::Catalog.call(directory: staging)
  destination = root.join("config/installation_catalog")
  # Publish the lock last: a concurrent reader can fail closed, never accept mixed versions.
  payloads.each do |name, bytes|
    Tempfile.create([ "catalog-", ".json" ], destination) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      file.fsync
      File.rename(file.path, destination.join(name))
    end
  end
end
puts "Catalog, schema and pins updated; review and commit all three together."
