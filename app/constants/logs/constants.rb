# frozen_string_literal: true

module Logs
  # Costanti del dominio log strutturati (rules/constants.md).
  module Constants
    # Retention di default (giorni) quando né progetto, né org, né god la impostano.
    RETENTION_DEFAULT_DAYS = 14
    # Numero massimo di voci accettate in un singolo POST /logs (oltre → R413).
    MAX_BATCH = 1000

    # Index: TTL della cache dei facet dell'header (dropdown environment via DISTINCT, chip
    # conteggi via GROUP BY level). Aggregano l'intero stream visibile — non i filtri di lista — quindi
    # ricalcolarli a ogni apertura/paginazione/filtro è un full-scan ripetuto su decine di milioni di
    # righe. TTL corto: un environment o un conteggio nuovo compare con al più questo ritardo (CYRA-59).
    FACETS_CACHE_TTL = 60.seconds

    # Finestra di collasso dell'enqueue degli alert sui log (Logs::Ingest::Record): un lotto di N log
    # error accodava un Alerting::EvaluateJob PER RIGA (fino a ~1,2M/min sulla coda :alerts), affamando
    # gli alert veri. Si accoda al più un job per (progetto, livello) per finestra; il throttle fine
    # per-regola resta in Alerting::Evaluate (CYRA-274, come metrics CYRA-48). Breve di proposito: deve
    # collassare i burst d'ingest, non throttlare l'utente (che quello lo fa Evaluate).
    ALERT_ENQUEUE_WINDOW = 60.seconds
  end
end
