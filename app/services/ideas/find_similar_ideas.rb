# frozen_string_literal: true

module Ideas
  # Idee simili a un testo libero (bozza di proposta): embed del testo → nearest neighbors coseno
  # sulla scope visibile all'account, soglia stretta (suggeriamo POSSIBILI doppioni, non risultati di
  # ricerca). Cross-progetto by design: la stessa proposta nasce spesso su un altro progetto.
  #
  # NESSUN filtro di stato: un'idea già convertita in ticket o archiviata è esattamente ciò che chi
  # sta scrivendo deve sapere — «esiste già ed è diventata quel ticket», «l'abbiamo già scartata».
  # Il pannello mostra lo stato accanto al titolo, così il suggerimento resta leggibile.
  #
  # Ritorna i record (con neighbor_distance) — decide l'umano, mai dedupe automatico.
  # Gemello di Ticketing::FindSimilarTickets: stessa infra, stesse soglie.
  class FindSimilarIdeas < ApplicationService
    TOP_K = 5
    # Più stretta della search (0.6): un suggerimento di doppione deve essere quasi-certo.
    MAX_DISTANCE = 0.45

    def initialize(scope:, text:, client: nil)
      @scope = scope
      @text = text.to_s.strip
      @client = client
    end

    def call
      vector = Embeddings::EmbedText.call(text: @text, client: @client)
      return vector if vector.err?

      candidates = @scope.reorder(nil).where.not(embedding: nil).current_embedding
                         .includes(:project)
                         .nearest_neighbors(:embedding, vector.value, distance: "cosine")
                         .limit(TOP_K)
                         .select { |idea| idea.neighbor_distance <= MAX_DISTANCE }
      Result.ok(candidates)
    end
  end
end
