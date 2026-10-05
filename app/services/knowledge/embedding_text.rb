# frozen_string_literal: true

require "digest"

module Knowledge
  # Testo canonico embeddato per una pagina KB + checksum di staleness. Funzione pura (niente
  # Result): title + kind + body (+ tech_spec se presente). Etichette FISSE non-i18n: il testo
  # embeddato deve essere locale-stabile (stessa pagina → stesso vettore, qualunque sia la lingua
  # dell'utente). Il clamp per documenti lunghi lo applica Embeddings::EmbedText (EMBED_MAX_CHARS).
  class EmbeddingText
    # Colonne che, se cambiate, rendono stale l'embedding (vedi UpdatePage → EmbedPageJob).
    WATCHED_COLUMNS = %w[title kind body tech_spec].freeze

    def self.call(page:)
      lines = [
        "Titolo: #{page.title}",
        "Tipo: #{page.kind}",
        "Contenuto: #{page.body}"
      ]
      # Solo se valorizzata: le pagine senza tecnico conservano lo stesso testo canonico → il loro
      # checksum non cambia → nessun re-embed di massa all'introduzione della colonna.
      lines << "Dettagli tecnici: #{page.tech_spec}" if page.tech_spec.present?
      lines.join("\n")
    end

    # La EMBEDDING_VERSION nel digest fa da leva di re-embed: bump della costante → tutti i
    # checksum divergono → il backfill ri-embedda l'intero parco senza migration.
    def self.checksum(page:)
      Digest::SHA256.hexdigest("#{Ai::Configuration.for_id(page.organization_id).embedding_version}\n#{call(page: page)}")
    end
  end
end
