# frozen_string_literal: true

module Errors
  # CYRA-49: backfill one-shot di mechanism.handled sugli eventi/gruppi PRE-esistenti alla feature.
  # Senza questo, i gruppi storici resterebbero has_unhandled=false → un crash preesistente
  # apparirebbe erroneamente come "gestito". Il dato è ancora recuperabile: il payload conservato è
  # lossless tranne PII e il mechanism NON è PII, quindi Errors::Ingest::Normalize.handled_in lo
  # estrae con la STESSA logica dell'ingest (solo veri booleani, ultima exception). Poi ricalcola
  # has_unhandled dei gruppi (true sse esiste almeno un'occorrenza non gestita). Idempotente.
  # Lancio manuale al deploy:
  #   bin/rails runner 'Errors::BackfillHandledJob.perform_later'
  class BackfillHandledJob < ApplicationJob
    queue_as :batch

    def perform
      Errors::Event.where(handled: nil).find_each do |event|
        value = Errors::Ingest::Normalize.handled_in(event.payload)
        event.update_columns(handled: value) unless value.nil?
      end

      # Accende il flag di gruppo dai valori appena popolati, MONOTÒNO: solo false→true. Un semplice
      # SET = EXISTS(...) lo spegnerebbe sui gruppi i cui eventi-crash sono già stati potati (>30g,
      # Errors::PruneEventsJob) — il flag deve sopravvivere alla potatura come events_count.
      Errors::Group.connection.execute(<<~SQL.squish)
        UPDATE errors_groups g
        SET has_unhandled = TRUE
        WHERE g.has_unhandled = FALSE
          AND EXISTS (SELECT 1 FROM errors_events e WHERE e.group_id = g.id AND e.handled = FALSE)
      SQL
    end
  end
end
