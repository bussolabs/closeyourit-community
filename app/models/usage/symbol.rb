# frozen_string_literal: true

module Usage
  # CYSK-29 — un simbolo VISTO in esecuzione: `route` è `Controller#action` (mai l'URL), `job` la
  # classe, `custom` una chiave letterale, `feature_view` la funzione di prodotto aperta (CYRA-733).
  # I conteggi sono indicativi, solo `last_seen_at` è portante: nessuna query confronta N con N−1, un
  # flush perso costa una finestra su un simbolo che si rivede subito dopo. Sempre fully-qualified
  # `::Usage::Symbol` (ombreggia il ::Symbol di Ruby).
  class Symbol < ApplicationRecord
    self.table_name = "usage_symbols"

    # CYRA-733 — `feature_view` è l'apertura di una FUNZIONE del prodotto: il simbolo è la chiave
    # stabile del catalogo (Usage::FeatureMap), non un nome di classe. Sta accanto a `route`, non al
    # suo posto: la rotta serve all'inventario del codice, la funzione a decidere cosa tenere.
    KINDS = %w[route job custom feature_view].freeze
    # I simboli vengono da payload di framework o da stringhe letterali: niente URL, niente
    # parametri, niente dati utente. Il pattern è il contratto.
    SYMBOL_FORMAT = %r{\A[A-Za-z0-9_:#./-]{1,200}\z}

    belongs_to :project, class_name: "Projects::Project"

    validates :kind, inclusion: { in: KINDS }
    validates :symbol, presence: true, format: { with: SYMBOL_FORMAT }
    validates :environment, presence: true

    scope :recent_first, -> { order(last_seen_at: :desc) }
  end
end
