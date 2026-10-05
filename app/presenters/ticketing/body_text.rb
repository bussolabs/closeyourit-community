# frozen_string_literal: true

module Ticketing
  # Rende scenari BDD e condizioni DoD in testo piano human-readable. Fonte unica riusata dove serve
  # una rappresentazione testuale del corpo strutturato: confronto dedup (ComparisonPresenter), diff di
  # cronologia (UpdateTicket → ActivityPresenter), testo semantico per l'embedding, output CLI. La resa
  # RICCA (card, tooltip) vive nelle view; qui c'è solo il testo condiviso.
  module BodyText
    module_function

    STEP_LABELS = {
      step_given: "Given",
      step_when: "When",
      step_then: "Then",
      step_expected: "Expected"
    }.freeze

    # `scenarios` = enumerabile di Ticketing::Scenario già ordinato (per un ticket: ticket.scenarios).
    def scenarios(scenarios)
      scenarios.each_with_index.filter_map do |scenario, index|
        steps = Ticketing::Scenario::STEP_FIELDS.filter_map do |field|
          value = scenario.public_send(field)
          "#{STEP_LABELS[field]} #{value}" if value.present?
        end
        next if steps.empty?

        header = scenario.title.present? ? "Scenario #{index + 1}: #{scenario.title}" : "Scenario #{index + 1}"
        [ header, *steps ].join("\n")
      end.join("\n\n")
    end

    # `conditions` = enumerabile di Ticketing::Condition ordinato.
    def conditions(conditions)
      conditions.filter_map { |condition| "- #{condition.text}" if condition.text.present? }.join("\n")
    end
  end
end
