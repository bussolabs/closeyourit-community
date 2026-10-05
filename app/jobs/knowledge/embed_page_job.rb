# frozen_string_literal: true

module Knowledge
  # Calcola e persiste l'embedding di una pagina KB (coda :ingest — network-bound, breve).
  # Enqueued dai mutation service (CreatePage sempre, UpdatePage solo su colonne watched).
  # Idempotente: checksum invariato → no-op. Su errore del servizio embedding RAISE → retry_on
  # di ApplicationJob (×3), poi la pagina resta stale: la ricerca semantica degrada, niente si rompe.
  class EmbedPageJob < ApplicationJob
    # CYRA-649 — corsia propria, MAI :ingest: un embed è una chiamata al servizio che gira sulla
    # stessa macchina e ne consuma la CPU, e i backfill notturni ne accodano migliaia insieme.
    # Sulla corsia dei dati mettevano in fila l'arrivo dei server e li facevano sembrare giù.
    queue_as :embeddings

    def perform(page_id:)
      page = Knowledge::Page.find_by(id: page_id)
      return if page.nil?
      Current.organization = page.organization # runs with this organization's AI settings (CYRA-914)

      checksum = Knowledge::EmbeddingText.checksum(page: page)
      return if page.embedding.present? && page.embedding_checksum == checksum

      result = Embeddings::EmbedText.call(text: Knowledge::EmbeddingText.call(page: page),
                                          label: "Knowledge::Page #{page.id}")
      raise result.error if result.err?

      # update_columns: colonna infrastrutturale — niente validazioni/callback/updated_at.
      # embedding_version: la ricerca semantica filtra per versione (CYRA-168), così un re-embed
      # in corso non mescola mai vettori di modelli diversi.
      page.update_columns(embedding: result.value, embedding_checksum: checksum,
                          embedded_at: Time.current,
                          embedding_version: Ai::Configuration.current.embedding_version)
    end
  end
end
