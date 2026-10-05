# frozen_string_literal: true

module Ticketing
  # Ricerca semantica sui ticket: embed della query (sync, con micro-cache) → nearest neighbors
  # coseno SULLA SCOPE GIÀ FILTRATA (RBAC + filtri toolbar applicati a monte) → rerank
  # cross-encoder che ordina E taglia il non pertinente → ids ordinati per pertinenza.
  #
  # Soglie e taglio vivono in Embeddings::Relevance, condivisi coi cloni di Knowledge e Ideas:
  # lo stesso difetto stava in tutte e tre le copie (CYRA-553).
  #
  # Result.ok(ids) anche a lista vuota — "non ho trovato niente" è una risposta, e il chiamante
  # la rende come tale. Result.err SOLO su servizio embedding giù → il chiamante degrada a ILIKE
  # senza mai mostrare errori. Il rerank invece degrada QUI (ordine coseno): perdere precisione
  # non giustifica perdere la feature.
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

    # reorder(nil): la scope arriva con l'ordinamento dell'index (created_at desc) che
    # prevarrebbe sulla distanza — qui comanda SOLO il coseno.
    # `first(RERANK_TOP_N)`: al cross-encoder arriva la testa della lista, non tutti i candidati.
    def nearest(vector)
      max_distance = Embeddings::Relevance.max_distance(@query)
      @scope.reorder(nil).where.not(embedding: nil).current_embedding
            .nearest_neighbors(:embedding, vector, distance: "cosine")
            .limit(Embeddings::Relevance::TOP_K)
            .select { |ticket| ticket.neighbor_distance <= max_distance }
            .first(Embeddings::Relevance::RERANK_TOP_N)
    end

    # Ordina E taglia col cross-encoder. Rerank non disponibile → ordine coseno (degrado interno):
    # in quel caso il taglio resta quello della distanza, che è meno preciso ma c'è.
    def rerank(candidates)
      documents = candidates.map do |ticket|
        "#{ticket.title}\n#{ticket.description}".first(Embeddings::Relevance::RERANK_TEXT_CHARS)
      end
      ranking = Embeddings::Rerank.call(query: @query, documents: documents, client: @client)
      return candidates.map(&:id) if ranking.err?

      ranking.value.filter_map { |index| candidates[index]&.id }
    end
  end
end
