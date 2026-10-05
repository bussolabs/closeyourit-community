# frozen_string_literal: true

require "rails_helper"

RSpec.describe Embeddings::VersionDrift, "query bindings" do
  after { Ai::Configuration.reset! }

  it "treats SQL punctuation in an organization model name as a literal version" do
    organization = create(:organization)
    organization.create_ai_setting!(mode: "variation", embedding_model: "model') OR TRUE --")
    Ai::Configuration.reset!
    version = Ai::Configuration.for(organization).embedding_version
    current = create(:ticket)
    current.update_columns(embedding: basis_vector(0), embedding_version: version)
    platform = create(:ticket)
    platform.update_columns(embedding: basis_vector(1), embedding_version: Ai::Configuration.for(nil).embedding_version)
    stale = create(:ticket)
    stale.update_columns(embedding: basis_vector(2), embedding_version: "retired-model")

    tickets = described_class.call.tables.find { |table| table.key == :tickets }

    expect(tickets.embedded).to eq(3)
    expect(tickets.current).to eq(2)
    expect(tickets.stale).to eq(1)
  end

  it "returns zero counts for an empty table" do
    tickets = described_class.call.tables.find { |table| table.key == :tickets }

    expect([ tickets.embedded, tickets.current, tickets.missing ]).to eq([ 0, 0, 0 ])
  end

  it "counts missing vectors strictly before the grace boundary" do
    now = Time.utc(2026, 10, 5, 12)
    cutoff = now - described_class::MISSING_GRACE
    [ cutoff - 1.second, cutoff, cutoff + 1.second ].each do |created_at|
      create(:ticket, created_at: created_at)
    end

    tickets = described_class.call(now: now).tables.find { |table| table.key == :tickets }

    expect(tickets.missing).to eq(1)
    expect(tickets.embedded).to eq(0)
  end
end
