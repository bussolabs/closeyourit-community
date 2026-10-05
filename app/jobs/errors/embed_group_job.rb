# frozen_string_literal: true

module Errors
  # Calcola e persiste l'embedding di un gruppo errori (coda :embeddings). Enqueued da
  # Errors::Ingest::Record SOLO su gruppo nuovo o title cambiato — mai per-occorrenza
  # (10k eventi identici = 1 embed). Checksum-guard idempotente come Ticketing::EmbedTicketJob.
  class EmbedGroupJob < ApplicationJob
    # CYRA-649 — corsia propria, MAI :ingest: un embed è una chiamata al servizio che gira sulla
    # stessa macchina e ne consuma la CPU, e i backfill notturni ne accodano migliaia insieme.
    # Sulla corsia dei dati mettevano in fila l'arrivo dei server e li facevano sembrare giù.
    queue_as :embeddings

    def perform(group_id:)
      group = Errors::Group.find_by(id: group_id)
      return if group.nil?
      Current.organization = group.project.organization # runs with this organization's AI settings (CYRA-914)

      checksum = Errors::EmbeddingText.checksum(group: group)
      return if group.embedding.present? && group.embedding_checksum == checksum

      result = Embeddings::EmbedText.call(text: Errors::EmbeddingText.call(group: group),
                                          label: "Errors::Group #{group.id}")
      raise result.error if result.err?

      # embedding_version: la ricerca semantica filtra per versione (CYRA-168), così un re-embed
      # in corso non mescola mai vettori di modelli diversi.
      group.update_columns(embedding: result.value, embedding_checksum: checksum,
                           embedded_at: Time.current,
                           embedding_version: Ai::Configuration.current.embedding_version)
    end
  end
end
