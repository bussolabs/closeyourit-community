# frozen_string_literal: true

module Wikitech
  # Search over the organization's cards, shared by the page and the CLI (CYRA-1130/1131): cards
  # close in meaning first (embedding, cosine, cross-encoder), then plain text matches not already
  # in. A card just created has no embedding yet, so the text branch is part of the search, not a
  # fallback. With the embedding service down the search is text only, never an error.
  class Search < ApplicationService
    Outcome = Data.define(:scope, :mode)

    def initialize(scope:, query:, client: nil)
      @scope = scope
      @query = query.to_s.strip
      @client = client
    end

    def call
      return Outcome.new(scope: @scope, mode: nil) if @query.blank?

      semantic = semantic_ids
      return Outcome.new(scope: @scope.text_search(@query), mode: :like) if semantic.nil?

      ordered = semantic + (text_ids - semantic)
      return Outcome.new(scope: @scope.none, mode: :semantic) if ordered.empty?

      Outcome.new(scope: @scope.reorder(nil).in_order_of(:id, ordered), mode: :semantic)
    end

    private

    # nil = embedding service unavailable.
    def semantic_ids
      vector = Embeddings::QueryVector.call(query: @query, client: @client)
      return nil if vector.err?

      candidates = nearest(vector.value)
      return [] if candidates.empty?

      documents = candidates.map { |entry| "#{entry.name}\n#{entry.summary}".first(Embeddings::Relevance::RERANK_TEXT_CHARS) }
      ranking = Embeddings::Rerank.call(query: @query, documents: documents, client: @client)
      return candidates.map(&:id) if ranking.err?

      ranking.value.filter_map { |index| candidates[index]&.id }
    end

    def nearest(vector)
      max_distance = Embeddings::Relevance.max_distance(@query)
      @scope.reorder(nil).where.not(embedding: nil).current_embedding
            .nearest_neighbors(:embedding, vector, distance: "cosine")
            .limit(Embeddings::Relevance::TOP_K)
            .select { |entry| entry.neighbor_distance <= max_distance }
            .first(Embeddings::Relevance::RERANK_TOP_N)
    end

    def text_ids = @scope.text_search(@query).reorder(updated_at: :desc, id: :desc).pluck(:id)
  end
end
