# frozen_string_literal: true

module Logs
  # CYRA-345: backfill del trace_id sui log storici (in retention) che ne sono privi.
  # L'identificativo di richiesta è spesso già scritto nel testo del messaggio (prefisso TaggedLogging
  # di Rails, Job ID di ActiveJob): lo si riconosce con la STESSA logica dell'ingest
  # (Logs::Ingest::Normalize.trace_id_from_message) e lo si normalizza sulla colonna del join,
  # marcandolo come dedotto dal messaggio (trace_id_extracted). Idempotente: solo i log con trace_id
  # nullo e un id riconoscibile vengono toccati; ripassarlo non cambia nulla. Immutabili (solo
  # created_at) → update_columns, niente callback/validazioni sullo stream append-only.
  #
  # CYRA-559: da one-shot a GIORNALIERO (config/recurring.yml). Un difetto del riconoscimento non si
  # limita ai log di quel momento: lascia scollegato per sempre tutto ciò che è entrato mentre era
  # attivo, e il rimedio — un runner lanciato a mano al deploy — è esattamente il passo che nessuno
  # esegue. È lo stesso motivo per cui i backfill degli embedding girano ogni notte (CYRA-232): il
  # giro ripara da sé la finestra di guasto. Costo tenuto basso dal pre-filtro SQL sui candidati
  # (TRACE_CANDIDATE_SQL) e dal select delle sole colonne che servono — senza, ogni giro
  # istanzierebbe l'intera tabella più grande del prodotto, jsonb `data` da 16 KB per riga incluso.
  # Lancio immediato (senza aspettare la notte):
  #   bin/rails runner 'Logs::BackfillTraceIdsJob.perform_later'
  class BackfillTraceIdsJob < ApplicationJob
    queue_as :batch

    def perform
      candidates.find_each do |entry|
        trace = Logs::Ingest::Normalize.trace_id_from_message(entry.message)
        next if trace.blank?

        entry.update_columns(trace_id: trace, trace_id_extracted: true)
      end
    end

    private

    def candidates
      Logs::Entry.where(trace_id: nil)
                 .where(Logs::Ingest::Normalize::TRACE_CANDIDATE_SQL)
                 .select(:id, :message)
    end
  end
end
