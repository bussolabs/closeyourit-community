module Types
  class TicketStatus < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :ticket_statuses
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true
    has_many :tickets,
             class_name: "Ticketing::Ticket",
             foreign_key: :status_id,
             inverse_of: :status,
             dependent: :restrict_with_error

    # Categoria del flusso (workflow): serve a sapere quali status contano come "completati"
    # nel progress delle milestone. open → da fare, in_progress → in corso, done → completato.
    enum :category, { open: 0, in_progress: 1, done: 2 }, prefix: :category

    normalizes :code, with: ->(code) { code.strip.downcase.gsub(/\s+/, "_") }
    normalizes :label, with: ->(label) { label.strip }

    validates :code, presence: true,
              format: { with: /\A[a-z][a-z0-9_]*\z/ },
              uniqueness: { scope: :organization_id }
    validates :label, presence: true
    validates :color, presence: true

    scope :active, -> { where(active: true) }
    scope :ordered, -> { order(:position, :label) }
    # Gate di revisione: gli status il cui ingresso avvisa il reviewer del ticket
    # (default "In Review", vedi Types::InstallDefaults). Predicato #review_gate? è automatico.
    scope :review_gates, -> { where(review_gate: true) }

    # Etichetta localizzata (CYRA-392): i code di default (Types::InstallDefaults) hanno una
    # traduzione i18n in it/en; uno status personalizzato dall'org non ce l'ha e ricade sulla label
    # del DB. Il code NON si tocca mai — filtri e URL condivisi ci si agganciano.
    def display_label
      I18n.t("ticketing.statuses.#{code}", default: label)
    end
  end
end
