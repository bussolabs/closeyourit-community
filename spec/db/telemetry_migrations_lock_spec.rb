# frozen_string_literal: true

require "rails_helper"

# The telemetry tables are monthly-partitioned and hold millions of rows in production (CYRA-750). A plain
# index or a validated CHECK there holds a lock that stops ingest during the release (CYRA-914 P7). Migrations
# from the first OTLP one on must build indexes concurrently per partition and add checks NOT VALID.
RSpec.describe "Migrations on the telemetry tables" do
  let(:telemetry) { Ops::Partitions.table_names.join("|") }
  let(:migrations) do
    Rails.root.glob("db/migrate/*.rb").select { |file| file.basename.to_s.to_i >= 20_261_004_230_000 }
  end

  it "never add a plain index on a telemetry table" do
    offenders = migrations.select { |file| file.read.match?(/add_index\s+:(#{telemetry})\b/) }

    expect(offenders.map { |file| file.basename.to_s }).to be_empty
  end

  it "never add a validated CHECK on a telemetry table" do
    offenders = migrations.select do |file|
      file.read.scan(/add_check_constraint\s+:(?:#{telemetry})\b[^\n]*/).any? { |line| !line.include?("validate: false") }
    end

    expect(offenders.map { |file| file.basename.to_s }).to be_empty
  end
end
