# frozen_string_literal: true

module Ideas
  # Calcola e persiste l'embedding di un'idea (coda :ingest — network-bound, breve).
  # Enqueued dai mutation service (CreateIdea sempre, UpdateIdea solo su colonne watched).
  # Idempotente: checksum invariato → no-op. Su errore del servizio embedding RAISE → retry_on
  # di ApplicationJob (×3), poi l'idea resta stale: la ricerca per significato e il suggerimento
  # dei doppioni degradano, niente si rompe.
  class EmbedIdeaJob < ApplicationJob
    # CYRA-649 — corsia propria, MAI :ingest: un embed è una chiamata al servizio che gira sulla
    # stessa macchina e ne consuma la CPU, e i backfill notturni ne accodano migliaia insieme.
    # Sulla corsia dei dati mettevano in fila l'arrivo dei server e li facevano sembrare giù.
    queue_as :embeddings

    def perform(idea_id:)
      idea = Ideas::Idea.find_by(id: idea_id)
      return if idea.nil?
      Current.organization = idea.project.organization # runs with this organization's AI settings (CYRA-914)

      checksum = Ideas::EmbeddingText.checksum(idea: idea)
      return if idea.embedding.present? && idea.embedding_checksum == checksum

      result = Embeddings::EmbedText.call(text: Ideas::EmbeddingText.call(idea: idea),
                                          label: "Ideas::Idea #{idea.id}")
      raise result.error if result.err?

      # update_columns: colonne infrastrutturali — niente validazioni/callback/updated_at. Qui
      # updated_at conta doppio: la bacheca ORDINA per ultimo movimento (CYRA-360), e un embedding
      # ricalcolato di notte dal backfill spingerebbe in cima idee che nessuno ha toccato.
      idea.update_columns(embedding: result.value, embedding_checksum: checksum,
                          embedded_at: Time.current,
                          embedding_version: Ai::Configuration.current.embedding_version)
    end
  end
end
