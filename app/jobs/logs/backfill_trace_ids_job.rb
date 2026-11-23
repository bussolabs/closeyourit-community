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
  #
  # CYRA-1233: il giro notturno guarda solo i log arrivati negli ultimi LOOKBACK. Il codice si ricava
  # già all'ingest, quindi il giro è solo una rete di sicurezza; senza finestra un log senza codice
  # riconoscibile tornava candidato OGNI notte e la durata cresceva con lo storico. La finestra è su
  # `created_at`, la chiave delle fette mensili: le fette vecchie non vengono più aperte. `since`
  # opzionale = ripasso da una data scelta (stesso schema di Uptime::RollupJob), da lanciare a mano
  # quando si corregge il riconoscimento.
  # Lancio immediato (senza aspettare la notte), o ripasso dello storico:
  #   bin/rails runner 'Logs::BackfillTraceIdsJob.perform_later'
  #   bin/rails runner 'Logs::BackfillTraceIdsJob.perform_later(since: 2.months.ago)'
  class BackfillTraceIdsJob < ApplicationJob
    queue_as :batch

    # Finestra del giro notturno: due giorni coprono anche una notte saltata.
    LOOKBACK = 2.days

    def perform(since: nil)
      candidates(since || LOOKBACK.ago).find_each do |entry|
        trace = Logs::Ingest::Normalize.trace_id_from_message(entry.message)
        next if trace.blank?

        entry.update_columns(trace_id: trace, trace_id_extracted: true)
      end
    end

    private

    def candidates(since)
      Logs::Entry.where(created_at: since..)
                 .where(trace_id: nil)
                 .where(Logs::Ingest::Normalize::TRACE_CANDIDATE_SQL)
                 .select(:id, :message)
    end
  end
end
