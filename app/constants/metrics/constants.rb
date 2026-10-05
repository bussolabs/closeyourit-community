# frozen_string_literal: true

module Metrics
  # Costanti del dominio metriche di performance (rules/constants.md): quanto si conserva, quanto
  # grande può essere un batch in ingresso e quando una soglia superata diventa un avviso. Ciò che
  # metriche ed errori condividono (fedeltà della telemetria, densità delle pagine) sta in
  # Monitoring::Constants.
  module Constants
    # Retention di default (giorni) — gerarchia god → org → progetto come i log.
    RETENTION_DEFAULT_DAYS = 30
    # Numero massimo di campioni accettati in un singolo POST /metrics (oltre → R413).
    MAX_BATCH = 1000

    # Tetto in BYTE del corpo dell'ingest bearer prima dell'enqueue, misurato su `request.content_length`
    # (CYRA-112). Distinto da MAX_BATCH, che limita il NUMERO di campioni ma non la loro dimensione: un
    # payload sotto il conteggio massimo ma sproporzionatamente grande raggiungeva comunque la coda
    # (Solid Queue su Postgres) come argomento del job, gonfiandola. Il gate (su `content_length`, nessun
    # parse) sta in TESTA alla catena via `prepend_before_action`, prima dell'autenticazione ingest che
    # parserebbe il body. Oltre → `R413-METRIC-006`. Stesso valore di
    # Errors::Constants::EVENTS_MAX_BYTES: le due porte hanno lo stesso peso ammesso.
    MAX_BYTES = 5.megabytes

    # Performance issue: numero di occorrenze (samples del gruppo) oltre cui scatta un alert
    # metric_threshold, quando il progetto non lo personalizza. 1 = avvisa alla prima comparsa
    # (il client emette già solo verdetti reali); l'owner può alzarlo per ridurre il rumore.
    ALERT_THRESHOLD_DEFAULT = 1

    # Cooldown dell'enqueue di metric_threshold per gruppo (Metrics::Ingest::Record): guard atomico
    # Rails.cache.write(unless_exist:) che gata l'accodamento sull'attraversamento della soglia, così
    # un burst di campioni (endpoint N+1 caldo, soglia default 1) non accoda un EvaluateJob per campione
    # saturando la coda :alerts (CYRA-48). Con una scadenza (a differenza di un flag permanente) un
    # enqueue fallito non silenzia il gruppo per sempre: alla scadenza il prossimo campione oltre soglia
    # riprova. Alerting::Evaluate deduplica poi la consegna col proprio throttle di regola.
    THRESHOLD_ALERT_COOLDOWN = 1.hour
  end
end
