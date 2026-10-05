# frozen_string_literal: true

module Crons
  # Ping immutabile del job (solo created_at): esito ok/fail + durata opzionale. Il monitor tiene
  # last_check_in_at denormalizzato per il controllo di scadenza senza join.
  class CheckIn < ApplicationRecord
    self.table_name = "crons_check_ins"

    belongs_to :monitor, class_name: "Crons::Monitor", inverse_of: :check_ins

    enum :status, { ok: 0, fail: 1 }, prefix: :status

    # CYRA-484 — il motivo del fallimento in parole: la prima riga dell'errore, non lo stack. Chi
    # manda un messaggio più lungo se lo vede tagliato invece di veder fallire il check-in.
    REASON_MAX_CHARS = 500

    validates :checked_in_at, presence: true
    validates :reason, length: { maximum: REASON_MAX_CHARS }, allow_nil: true

    scope :recent, -> { order(checked_in_at: :desc) }
  end
end
