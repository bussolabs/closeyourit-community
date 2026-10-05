# frozen_string_literal: true

module Ticketing
  # Calcola e persiste l'embedding di un ticket (coda :ingest — network-bound, breve).
  # Enqueued dai mutation service (CreateTicket sempre, UpdateTicket solo su colonne watched).
  # Idempotente: checksum invariato → no-op (dedupe di storm e replay). Su errore del servizio
  # embedding RAISE → retry_on di ApplicationJob (×3), poi il ticket resta semplicemente stale:
  # la ricerca semantica degrada, niente si rompe.
  class EmbedTicketJob < ApplicationJob
    # CYRA-649 — corsia propria, MAI :ingest: un embed è una chiamata al servizio che gira sulla
    # stessa macchina e ne consuma la CPU, e i backfill notturni ne accodano migliaia insieme.
    # Sulla corsia dei dati mettevano in fila l'arrivo dei server e li facevano sembrare giù.
    queue_as :embeddings

    def perform(ticket_id:)
      ticket = Ticketing::Ticket.find_by(id: ticket_id)
      return if ticket.nil?
      Current.organization = ticket.project.organization # runs with this organization's AI settings (CYRA-914)

      checksum = Ticketing::EmbeddingText.checksum(ticket: ticket)
      return if ticket.embedding.present? && ticket.embedding_checksum == checksum

      result = Embeddings::EmbedText.call(text: Ticketing::EmbeddingText.call(ticket: ticket),
                                          label: "Ticketing::Ticket #{ticket.id}")
      raise result.error if result.err?

      # update_columns: colonna infrastrutturale — niente validazioni/callback/updated_at.
      # embedding_version: la ricerca semantica filtra per versione (CYRA-168), così un re-embed
      # in corso non mescola mai vettori di modelli diversi.
      ticket.update_columns(embedding: result.value, embedding_checksum: checksum,
                            embedded_at: Time.current,
                            embedding_version: Ai::Configuration.current.embedding_version)
    end
  end
end
