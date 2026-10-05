# frozen_string_literal: true

require "digest"

module Ticketing
  # Testo canonico embeddato per un ticket + checksum di staleness. Funzione pura (niente
  # Result): title + kind + description + scenari BDD + analisi tecnica. I COMMENTI e le condizioni
  # DoD restano fuori: forzerebbero re-embed inutili e diluirebbero la semantica del problema (per il
  # RAG entrano nel prompt a retrieval-time, non nell'embedding).
  #
  # Etichette FISSE non-i18n: il testo embeddato deve essere locale-stabile (stesso ticket →
  # stesso vettore, qualunque sia la lingua dell'utente).
  class EmbeddingText
    # Colonne del ticket che, se cambiate, rendono stale l'embedding. Gli scenari sono record a parte
    # (non compaiono in ticket.saved_changes): il loro cambio lo intercetta UpdateTicket a valle.
    WATCHED_COLUMNS = %w[title kind description technical_analysis].freeze

    def self.call(ticket:)
      scenarios = Ticketing::BodyText.scenarios(ticket.scenarios)
      [
        "Titolo: #{ticket.title}",
        "Tipo: #{ticket.kind}",
        ("Descrizione: #{ticket.description}" if ticket.description.present?),
        ("Scenari:\n#{scenarios}" if scenarios.present?),
        ("Analisi tecnica: #{ticket.technical_analysis}" if ticket.technical_analysis.present?)
      ].compact.join("\n")
    end

    # La EMBEDDING_VERSION nel digest fa da leva di re-embed: bump della costante → tutti i
    # checksum divergono → il backfill ri-embedda l'intero parco senza migration.
    def self.checksum(ticket:)
      Digest::SHA256.hexdigest("#{Ai::Configuration.for_id(ticket.project.organization_id).embedding_version}\n#{call(ticket: ticket)}")
    end
  end
end
