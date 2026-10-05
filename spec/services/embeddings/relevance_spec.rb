# frozen_string_literal: true

require "rails_helper"

RSpec.describe Embeddings::Relevance do
  describe ".max_distance" do
    it "una parola sola: soglia più stretta (a 0.6 passava di tutto — CYRA-553)" do
      expect(described_class.max_distance("crash")).to eq(described_class::SHORT_QUERY_MAX_DISTANCE)
    end

    it "due o più parole: soglia larga, la query porta già contesto suo" do
      expect(described_class.max_distance("crash al login")).to eq(described_class::MAX_DISTANCE)
    end

    it "spazi di troppo non contano come parole" do
      expect(described_class.max_distance("  crash   ")).to eq(described_class::SHORT_QUERY_MAX_DISTANCE)
    end
  end

  describe ".relevant_indexes" do
    it "tiene le posizioni sopra la soglia di pertinenza, nell'ordine del rerank" do
      ranking = [ { index: 3, score: 0.9 }, { index: 1, score: 0.4 } ]

      expect(described_class.relevant_indexes(ranking)).to eq([ 3, 1 ])
    end

    it "scarta il rumore sotto soglia: una parola inventata non deve pescare nulla" do
      ranking = [ { index: 0, score: 0.001 }, { index: 2, score: 0.0004 } ]

      expect(described_class.relevant_indexes(ranking)).to eq([])
    end

    it "il punteggio esattamente a soglia resta dentro" do
      ranking = [ { index: 0, score: described_class::MIN_SCORE } ]

      expect(described_class.relevant_indexes(ranking)).to eq([ 0 ])
    end
  end
end
