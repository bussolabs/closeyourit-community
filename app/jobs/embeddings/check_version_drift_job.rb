# frozen_string_literal: true

module Embeddings
  # Controllo periodico (recurring.yml, daily) di ciò che è invisibile alla ricerca semantica. Se una o
  # più tabelle hanno righe a versione obsoleta (stale) o mai indicizzate oltre la grazia (missing) —
  # vedi Embeddings::VersionDrift — logga un WARN strutturato coi conteggi, così il degrado (per
  # costruzione SILENZIOSO) diventa rilevabile dal log aggregator invece di restare nascosto per
  # giorni. Nessun drift → nessun log (niente rumore).
  #
  # Sola LETTURA: rileva ma non ripara. Il rimedio dipende dalla causa: versione OBSOLETA/ASSENTE →
  # ri-embed o timbratura (Ticketing::BackfillEmbeddingsJob & co., Embeddings::BackfillVersionJob);
  # mai indicizzate → gli stessi backfill, ora in recurring.yml, riparano da soli. Vedi CYRA-206/232.
  class CheckVersionDriftJob < ApplicationJob
    queue_as :batch

    def perform
      report = Embeddings::VersionDrift.call
      return unless report.any_drift?

      detail = report.drifted.map { |table| "#{table.key}=stale:#{table.stale}/missing:#{table.missing}" }.join(" ")
      Rails.logger.warn(
        "Embeddings::CheckVersionDriftJob drift rilevato: #{report.total_stale} righe a versione vecchia " \
        "+ #{report.total_missing} mai indicizzate, invisibili alla ricerca semantica — #{detail}"
      )
    end
  end
end
