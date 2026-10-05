# frozen_string_literal: true

module Ideas
  # Ricerca semantica sulle idee: embed della query (sync, con micro-cache) → nearest neighbors
  # coseno SULLA SCOPE GIÀ FILTRATA (visibilità + filtri toolbar applicati a monte) → rerank
  # cross-encoder che ordina E taglia il non pertinente → ids ordinati per pertinenza.
  #
  # Result.ok(ids) anche a lista vuota; Result.err SOLO su servizio embedding giù → il chiamante
  # degrada a ILIKE senza mai mostrare errori. Il rerank invece degrada QUI (ordine coseno).
  # Clone di Knowledge::SemanticSearch: stessa infra, stesse soglie (Embeddings::Relevance).
  class SemanticSearch < ApplicationService
    def initialize(scope:, query:, client: nil)
      @scope = scope
      @query = query.to_s.strip
      @client = client
    end

    def call
      vector = query_vector
      return vector if vector.err?

      candidates = nearest(vector.value)
      return Result.ok([]) if candidates.empty?

      Result.ok(rerank(candidates))
    end

    private

    def query_vector
      Embeddings::QueryVector.call(query: @query, client: @client)
    end

    # reorder(nil): la scope arriva con l'ordinamento della bacheca (ultimo movimento) che
    # prevarrebbe sulla distanza — qui comanda SOLO il coseno. Al cross-encoder arriva la sola
    # testa della lista.
    def nearest(vector)
      max_distance = Embeddings::Relevance.max_distance(@query)
      @scope.reorder(nil).where.not(embedding: nil).current_embedding
            .nearest_neighbors(:embedding, vector, distance: "cosine")
            .limit(Embeddings::Relevance::TOP_K)
            .select { |idea| idea.neighbor_distance <= max_distance }
            .first(Embeddings::Relevance::RERANK_TOP_N)
    end

    # Ordina E taglia col cross-encoder. Rerank non disponibile → ordine coseno (degrado interno).
    def rerank(candidates)
      documents = candidates.map do |idea|
        "#{idea.title}\n#{idea.problem}".first(Embeddings::Relevance::RERANK_TEXT_CHARS)
      end
      ranking = Embeddings::Rerank.call(query: @query, documents: documents, client: @client)
      return candidates.map(&:id) if ranking.err?

      ranking.value.filter_map { |index| candidates[index]&.id }
    end
  end
end
