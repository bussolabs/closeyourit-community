# frozen_string_literal: true

module Metrics
  # Persiste un batch di campioni di metrica in background (coda :ingest). Un solo job per richiesta
  # (CYRA-43): Record.call_batch raggruppa per fingerprint e applica un update aggregato per gruppo.
  # Idempotente (dedup su sample_id); se il progetto è stato cancellato, scarta senza errore.
  class IngestJob < ApplicationJob
    queue_as :ingest

    # Tetto per progetto (CYRA-850): dentro `ingest` l'ordine è di arrivo, quindi un'applicazione
    # monitorata rumorosa occupava tutti i thread della corsia e le altre restavano fuori. Con il
    # tetto sotto il numero di thread resta sempre almeno uno slot per chi non sta facendo rumore.
    limits_concurrency to: 2, key: ->(project_id:, **) { "metrics:ingest:#{project_id}" }

    def perform(project_id:, payload:)
      project = Projects::Project.find_by(id: project_id)
      return if project.nil?

      result = Metrics::Ingest::Record.call_batch(project: project, payloads: Array.wrap(payload))
      log_rejected(result.value.rejected, project_id) if result.ok?
    end

    private

    # Osservabilità: senza questo log un campione con kind/subtype invalido verrebbe scartato in
    # silenzio assoluto — il client riceve 202 ma il dato sparisce senza traccia. Aggregato per codice
    # (un batch può scartarne molti): una riga per codice col conteggio, non una per campione.
    def log_rejected(rejected, project_id)
      rejected.tally.each do |code, count|
        Rails.logger.warn("Metrics::IngestJob #{count} campione/i scartato/i: #{code} project_id=#{project_id}")
      end
    end
  end
end
