module Ticketing
  # Uno scenario BDD del ticket: un Given/When/Then/Expected human-simple, con titolo opzionale.
  # Un ticket ha N scenari ordinati (happy path + limite + errore…), tutti i kind. Sostituisce le
  # 4 colonne piatte step_* che stavano su ticketing_tickets (un solo scenario, solo bug).
  # Prefisso step_ uniforme su tutte e 4 (when/then sono keyword Ruby).
  class Scenario < ApplicationRecord
    STEP_FIELDS = %i[step_given step_when step_then step_expected].freeze

    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :scenarios

    # Ortografia italiana prima del salvataggio (vedi Text::ItalianOrthography): gli scenari sono la
    # parte del ticket che l'assistente AI scrive più spesso, e si leggono uno accanto all'altro —
    # un accento mancante lì salta all'occhio più che altrove.
    normalizes :title, with: ->(value) { Text::ItalianOrthography.correct(value).strip }
    normalizes :step_given, with: ->(value) { Text::ItalianOrthography.correct(value).strip }
    normalizes :step_when, with: ->(value) { Text::ItalianOrthography.correct(value).strip }
    normalizes :step_then, with: ->(value) { Text::ItalianOrthography.correct(value).strip }
    normalizes :step_expected, with: ->(value) { Text::ItalianOrthography.correct(value).strip }

    # Uno scenario ha senso solo con almeno uno step: il titolo da solo non basta. I form scartano
    # le righe step-less via reject_if (vedi Ticketing::Ticket); questa guardia protegge la creazione diretta.
    validate :at_least_one_step

    scope :ordered, -> { order(:position, :created_at) }

    def steps?
      STEP_FIELDS.any? { |field| public_send(field).present? }
    end

    private

    def at_least_one_step
      return if steps?

      errors.add(:base, :steps_required)
    end
  end
end
