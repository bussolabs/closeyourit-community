# frozen_string_literal: true

require "digest"

module Embeddings
  # Embedding di una QUERY con micro-cache (Solid Cache). Distinto da EmbedText perché la stessa
  # domanda viene ri-embeddata di continuo — refine dei filtri, paginazione, pannelli correlati —
  # e ogni giro sarebbe un round-trip al servizio.
  #
  # La chiave è VOLUTAMENTE condivisa tra i domini (ticket, knowledge, pagine correlate): la
  # stessa frase produce lo stesso vettore, chi la chiede dopo la trova già pronta. La versione
  # dell'embedding è nella chiave, quindi un bump di EMBEDDING_VERSION invalida tutto da sé.
  #
  # Stessa semantica di EmbedText: Result.ok(vector) oppure Result.err col servizio giù — sono i
  # chiamanti a degradare in silenzio (ILIKE, ordine per collegamento, ecc.).
  class QueryVector < ApplicationService
    QUERY_CACHE_TTL = 1.hour

    def initialize(query:, client: nil)
      @query = query.to_s.strip
      @client = client
    end

    def call
      cached = Rails.cache.read(cache_key)
      return Result.ok(cached) if cached.present?

      result = Embeddings::EmbedText.call(text: @query, client: @client)
      Rails.cache.write(cache_key, result.value, expires_in: QUERY_CACHE_TTL) if result.ok?
      result
    end

    private

    def cache_key
      [ "embed-query", Ai::Configuration.current.embedding_version, Digest::SHA256.hexdigest(@query) ]
    end
  end
end
