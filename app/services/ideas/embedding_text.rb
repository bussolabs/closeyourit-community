# frozen_string_literal: true

require "digest"

module Ideas
  # Testo canonico embeddato per un'idea + checksum di staleness. Funzione pura (niente Result):
  # titolo + problema + soluzione. Commenti, casi d'uso e stakeholder restano FUORI, come i commenti
  # dei ticket: cambiano di continuo (ogni commento forzerebbe un re-embed) e diluiscono la semantica
  # della proposta, che è ciò su cui si riconosce un doppione.
  #
  # Etichette FISSE non-i18n: il testo embeddato deve essere locale-stabile (stessa idea → stesso
  # vettore, qualunque sia la lingua di chi la scrive).
  class EmbeddingText
    # Colonne che, se cambiate, rendono stale l'embedding (vedi UpdateIdea → EmbedIdeaJob).
    WATCHED_COLUMNS = %w[title problem solution].freeze

    def self.call(idea:)
      [
        "Titolo: #{idea.title}",
        "Problema: #{idea.problem}",
        ("Soluzione: #{idea.solution}" if idea.solution.present?)
      ].compact.join("\n")
    end

    # La EMBEDDING_VERSION nel digest fa da leva di re-embed: bump della costante → tutti i
    # checksum divergono → il backfill ri-embedda l'intero parco senza migration.
    def self.checksum(idea:)
      Digest::SHA256.hexdigest("#{Ai::Configuration.for_id(idea.organization_id).embedding_version}\n#{call(idea: idea)}")
    end
  end
end
