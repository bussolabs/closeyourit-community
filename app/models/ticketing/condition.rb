module Ticketing
  # Una condizione della Definition of Done (DoD) del ticket: una riga di testo human-simple che
  # dice "quando questo è fatto". Un ticket ha 0..N condizioni ordinate, sempre opzionali.
  #
  # CYRA-1317 — a plain-text acceptance item: same table and codes as the Given/When/Then ones.
  class Condition < AcceptanceItem
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :conditions

    # Ortografia italiana prima del salvataggio: le condizioni le compone l'assistente AI insieme al
    # resto del corpo del ticket (vedi Text::ItalianOrthography).
    normalizes :text, with: ->(value) { Text::ItalianOrthography.correct(value).strip }

    validates :text, presence: true
  end
end
