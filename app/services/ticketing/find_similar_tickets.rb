# frozen_string_literal: true

module Ticketing
  # Ticket simili a un testo libero (draft di creazione): embed del testo → nearest neighbors
  # coseno sulla scope ricevuta, soglia stretta (suggeriamo POSSIBILI duplicati, non risultati di
  # ricerca). Decide sempre l'umano: nessun dedupe automatico.
  #
  # Il perimetro NON lo decide questo service: progetto e stato arrivano già dentro la scope, e la
  # soglia arriva dal chiamante. I due punti che lo usano guardano lo stesso archivio con due
  # sensibilità diverse — il pannello del form propone (DUPLICATE_PANEL_SIMILARITY), la pagina di
  # confronto ferma (DUPLICATE_GATE_SIMILARITY).
  class FindSimilarTickets < ApplicationService
    TOP_K = 5

    # La soglia si applica alla percentuale ARROTONDATA, cioè allo stesso numero che si legge in
    # pagina. Filtrando sulla distanza grezza, una somiglianza di 0,896 sarebbe scritta «90%» e
    # rifiutata da una soglia del 90%: il numero mostrato direbbe una cosa e il comportamento
    # un'altra, sulla stessa riga.
    #
    # Il record non esce da qui: `neighbor_distance` è un attributo che il gem `neighbor` attacca
    # SOLO ai record caricati per vicinanza, e un Ticket qualunque non ce l'ha. Confinarlo nel Data
    # evita che una view lo legga su un ticket arrivato da un'altra strada e mostri una somiglianza
    # inventata. Fuori esce la percentuale, che è la forma in cui se ne parla.
    Match = Data.define(:ticket, :distance, :similarity)

    def initialize(scope:, text:, min_similarity: Constants::DUPLICATE_PANEL_SIMILARITY, client: nil)
      @scope = scope
      @text = text.to_s.strip
      @min_similarity = min_similarity
      @client = client
    end

    def call
      vector = Embeddings::EmbedText.call(text: @text, client: @client)
      return vector if vector.err?

      matches = @scope.reorder(nil).where.not(embedding: nil).current_embedding
                      .includes(:status, :project)
                      .nearest_neighbors(:embedding, vector.value, distance: "cosine")
                      .limit(TOP_K)
                      .map { |ticket| build_match(ticket) }
                      .select { |match| match.similarity >= @min_similarity }
      Result.ok(matches)
    end

    private

    def build_match(ticket)
      Match.new(ticket: ticket, distance: ticket.neighbor_distance,
                similarity: Embeddings::Similarity.percent(ticket.neighbor_distance))
    end
  end
end
