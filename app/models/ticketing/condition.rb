module Ticketing
  # Una condizione della Definition of Done (DoD) del ticket: una riga di testo human-simple che
  # dice "quando questo è fatto". Un ticket ha 0..N condizioni ordinate, sempre opzionali.
  class Condition < ApplicationRecord
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :conditions

    # Ortografia italiana prima del salvataggio: le condizioni le compone l'assistente AI insieme al
    # resto del corpo del ticket (vedi Text::ItalianOrthography).
    normalizes :text, with: ->(value) { Text::ItalianOrthography.correct(value).strip }

    validates :text, presence: true

    scope :ordered, -> { order(:position, :created_at) }
  end
end
