# frozen_string_literal: true

module Ops
  # Tiene pronte le fette future delle tabelle di telemetria (CYRA-750). Gira ogni notte prima delle
  # potature: se il mese nuovo non avesse la sua fetta, le righe finirebbero in quella di riserva —
  # leggibili come sempre, ma non più staccabili in un istante, e con la fetta vera che a quel punto
  # non si può nemmeno più creare finché la riserva non è vuota.
  #
  # Idempotente: crea solo ciò che manca, e nel caso normale non scrive niente.
  class EnsurePartitionsJob < ApplicationJob
    queue_as :maintenance

    def perform
      created = Ops::Partitions::Ensure.call
      Rails.logger.info("[partitions] fette create: #{created.join(', ')}") if created.any?
    end
  end
end
