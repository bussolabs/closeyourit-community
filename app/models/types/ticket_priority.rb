module Types
  class TicketPriority < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :ticket_priorities
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true
    has_many :tickets,
             class_name: "Ticketing::Ticket",
             foreign_key: :priority_id,
             inverse_of: :priority,
             dependent: :restrict_with_error

    normalizes :code, with: ->(code) { code.strip.downcase.gsub(/\s+/, "_") }
    normalizes :label, with: ->(label) { label.strip }

    validates :code, presence: true,
              format: { with: /\A[a-z][a-z0-9_]*\z/ },
              uniqueness: { scope: :organization_id }
    validates :label, presence: true
    validates :color, presence: true

    scope :active, -> { where(active: true) }
    scope :ordered, -> { order(:position, :label) }

    # Etichetta localizzata (CYRA-392): i code di default (low/medium/high) hanno una traduzione
    # i18n; una priorità personalizzata dall'org ricade sulla label del DB. Il code non si tocca.
    def display_label
      I18n.t("ticketing.priorities.#{code}", default: label)
    end
  end
end
