# frozen_string_literal: true

module Types
  # Stato di una funzionalità su una piattaforma (non pianificata, disponibile, in dismissione…).
  # Lookup org-scoped, gemella di Types::TicketStatus: label/color editabili, `category` fissa.
  # I default arrivano da Types::InstallDefaults.
  class FeatureStatus < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :feature_statuses
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_many :feature_platforms,
             class_name: "Connections::FeaturePlatform",
             foreign_key: :status_id,
             inverse_of: :status,
             dependent: :restrict_with_error

    # Semantica del ciclo di vita: guida l'icona della cella, il marker "versione mancante" e le
    # validazioni. Non è un'etichetta (quella è `label`, rinominabile): aggiungere una categoria
    # significa toccare il codice che la interpreta, quindi enum e non lookup.
    enum :category,
         { unplanned: 0, planned: 1, in_development: 2, available: 3, deprecated: 4, not_applicable: 5 },
         prefix: :category

    normalizes :code, with: ->(code) { code.strip.downcase.gsub(/\s+/, "_") }
    normalizes :label, with: ->(label) { label.strip }

    validates :code, presence: true,
              format: { with: /\A[a-z][a-z0-9_]*\z/ },
              uniqueness: { scope: :organization_id }
    validates :label, presence: true
    validates :color, presence: true

    scope :active, -> { where(active: true) }
    scope :ordered, -> { order(:position, :label) }

    # "Rilasciato" = la funzionalità è (o è stata) nelle mani degli utenti, quindi ci si aspetta di
    # sapere da quale versione. Le celle rilasciate senza versione sono segnalate, non impedite.
    def released? = category_available? || category_deprecated?
  end
end
