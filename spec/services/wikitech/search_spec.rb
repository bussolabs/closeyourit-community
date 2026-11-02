# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::Search do
  let(:organization) { create(:organization) }
  let(:scope) { organization.wikitech_entries.ordered }
  let!(:engine) { create(:wikitech_entry, organization: organization, name: "Godot", summary: "Game engine") }
  let!(:tracker) { create(:wikitech_entry, organization: organization, name: "Plane", summary: "Ticket tracker") }
  let(:vector) { Array.new(1024, 0.1) }

  it "returns the whole scope without a query" do
    expect(described_class.call(scope: scope, query: " ")).to have_attributes(mode: nil, scope: scope)
  end

  it "falls back to text search when the embedding service is down" do
    allow(Embeddings::QueryVector).to receive(:call).and_return(Result.err(AppError.new("down", code: "R502-AI-001")))

    outcome = described_class.call(scope: scope, query: "ticket")

    expect(outcome.mode).to eq(:like)
    expect(outcome.scope).to contain_exactly(tracker)
  end

  it "puts cards close in meaning first, then text matches, then nothing else" do
    engine.update_columns(embedding: vector, embedding_version: Ai::Configuration.current.embedding_version)
    allow(Embeddings::QueryVector).to receive(:call).and_return(Result.ok(vector))
    allow(Embeddings::Rerank).to receive(:call).and_return(Result.ok([ 0 ]))

    outcome = described_class.call(scope: scope, query: "tracker")

    expect(outcome.mode).to eq(:semantic)
    expect(outcome.scope.to_a).to eq([ engine, tracker ])
    # The reranker only orders: its scores are too low on Italian cards to be a cutoff.
    expect(Embeddings::Rerank).to have_received(:call).with(hash_including(min_score: nil))
  end

  it "keeps the cosine order when the reranker is unavailable and answers empty when nothing matches" do
    allow(Embeddings::QueryVector).to receive(:call).and_return(Result.ok(vector))
    allow(Embeddings::Rerank).to receive(:call).and_return(Result.err(AppError.new("x", code: "R503-AI-002")))

    outcome = described_class.call(scope: scope, query: "zzzz")

    expect(outcome.scope).to be_empty
    engine.update_columns(embedding: vector, embedding_version: Ai::Configuration.current.embedding_version)
    expect(described_class.call(scope: scope, query: "zzzz").scope.to_a).to eq([ engine ])
  end
end
