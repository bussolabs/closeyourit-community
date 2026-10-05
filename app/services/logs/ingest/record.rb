# frozen_string_literal: true

module Logs
  module Ingest
    # Persiste un batch di log con un solo `insert_all` (i log sono alto-volume). Idempotente su
    # (project_id, event_id) via ON CONFLICT DO NOTHING. project_id è sempre quello passato
    # (anti-BOLA): un eventuale project_id nel payload viene ignorato. Ritorna il numero di righe
    # effettivamente inserite (duplicati skippati esclusi).
    class Record < ApplicationService
      def initialize(project:, payload:)
        @project = project
        @payload = payload
      end

      # Predica di validità di un item (stessa logica di reject di #normalize_item): un Hash con message
      # non vuoto. Esposta per il pre-check sincrono del controller (segnala un batch interamente
      # scartato) senza divergere dal filtro applicato qui in fase di persistenza. Delega al predicato
      # LEGGERO Normalize.message_present? (CYRA-58): il thread web non riesegue la Normalize completa
      # — deep_clean + scrub ricorsivo degli attributes — di ogni item del batch; quel lavoro resta nel job.
      def self.acceptable?(item)
        Normalize.message_present?(item)
      end

      def call
        normalized = Array.wrap(@payload).filter_map { |item| normalize_item(item) }
        return Result.ok(0) if normalized.empty?

        # CYRA-750 — nessun bersaglio sul conflitto: la tabella è divisa a fette e su una tabella
        # divisa PostgreSQL accetta un indice unico solo se contiene la colonna del tempo, che
        # renderebbe diversa ogni riconsegna. L'unicità di [progetto, evento] vive quindi sulla SINGOLA
        # fetta (Ops::Partitions) e «salta ciò che viola un vincolo unico qualsiasi» la rispetta
        # esattamente come prima. Resta scoperta solo una riconsegna a cavallo del cambio di mese.
        result = Logs::Entry::Bulk.insert_all(normalized.map { |item| attributes_for(item) },
                                              returning: %w[id])
        track_source(normalized)
        Notify.call(project: @project, result: result)
        Result.ok(result.count)
      end

      private

      # Item normalizzato valido, oppure nil se va scartato (non è un Hash, o message vuoto): senza
      # validazioni di model su insert_all, è qui che si tiene fuori la spazzatura. Il filtro passa dal
      # predicato leggero Normalize.message_present? (stesso di .acceptable?): la Normalize completa gira
      # solo sugli item che restano — mai sulla spazzatura. Restituisce il Normalized (non le sole
      # colonne) così il batch può anche registrare la fonte (sdk).
      def normalize_item(item)
        return nil unless Normalize.message_present?(item)

        Normalize.call(payload: item)
      end

      # Una sola registrazione della fonte per batch (i log sono alto-volume): il primo sdk non-blank del
      # batch + l'istante di attività più recente. No-op se nessun item porta l'identità del client.
      def track_source(normalized)
        ::Ingest::SourceTracking.track_batch(project: @project, items: normalized)
      end

      def attributes_for(normalized)
        {
          project_id: @project.id,
          event_id: normalized.event_id,
          level: Logs::Entry.levels.fetch(normalized.level),
          message: normalized.message,
          data: normalized.data,
          logger_name: normalized.logger_name,
          trace_id: normalized.trace_id,
          trace_id_extracted: normalized.trace_id_extracted,
          environment: normalized.environment,
          release: normalized.release,
          occurred_at: normalized.occurred_at,
          # CYRA-348 — l'impronta si calcola QUI, all'ingresso: raggruppare a runtime su decine di
          # migliaia di righe costerebbe a ogni caricamento della pagina.
          fingerprint: Logs::Fingerprint.call(message: normalized.message, level: normalized.level),
          created_at: Time.current
        }
      end
    end
  end
end
