# frozen_string_literal: true

CloseYourIt.init do |config|
  config.endpoint_url = ENV.fetch("CLOSEYOURIT_ENDPOINT_URL", nil)
  config.token = ENV.fetch("CLOSEYOURIT_TOKEN", nil)
  config.project_id = ENV.fetch("CLOSEYOURIT_PROJECT_ID", nil)
  config.environment = ENV.fetch("CLOSEYOURIT_ENVIRONMENT", Rails.env)

  # Guard anti-ricorsione. CloseYourIt monitora SÉ STESSO: un errore del proprio canale di notifica
  # non può generare una notifica sullo stesso canale, o il loop si chiude e si autoalimenta.
  # Successo davvero il 2026-07-29: Solid Cable su SQLite va in lock sotto burst → BusyException in
  # Puma → l'SDK la manda all'ingest → Errors::Ingest::Record persiste E fa broadcast Turbo → il
  # broadcast riscrive sul cable → altro lock. 200.670 eventi in 8 ore (norma ~200/giorno), 8,6 GB di
  # payload, il disco di sentinel dall'86%. Il guadagno dell'anello è > 1: tolta la causa scatenante
  # (un backfill), il loop restava. Il matcher è un Regexp perché l'SDK confronta i nomi degli
  # ancestor E il messaggio: l'eccezione che arriva è il wrapper ActiveRecord::StatementTimeout, che
  # NON ha SQLite3::BusyException fra gli antenati ma se lo porta nel messaggio.
  config.excluded_exceptions += [ /SQLite3::BusyException/ ]

  # Tabelle dove atterra la telemetria/ingest del prodotto stesso (vedi db/migrate
  # create_errors_groups/errors_events, create_metrics_groups/metrics_samples,
  # create_logs_entries/logs_links). Le scritture/letture del SELF-MONITORING su queste tabelle sono
  # il costo della misurazione, non un difetto del prodotto, e a soglia 250 ms coprono il segnale
  # vero (query di prodotto). closeyourit-ruby 0.6.1 non espone un knob dedicato per escludere query
  # per tabella dallo slow-query capture (Configuration#excluded_exceptions filtra solo eccezioni);
  # l'unico punto d'innesto generico è `before_send`, invocato da Client#capture_event su OGNI evento
  # prima della spedizione — qui filtriamo solo gli eventi kind=slow_query il cui SQL tocca una
  # tabella interna. obfuscate_sql sostituisce solo literal stringa/numero, non gli identificatori:
  # il nome tabella resta leggibile nell'SQL offuscato.
  internal_telemetry_tables = /\b(errors_events|errors_groups|metrics_samples|metrics_groups|logs_entries|logs_links)\b/

  # Corsia dei job che RICEVE i dati (config/queue.yml). Una metrica di job su questa corsia si
  # spedisce come un job su questa stessa corsia: se è in ritardo, misurarla la allunga (CYRA-849).
  ingest_queue = "ingest"

  config.before_send = lambda do |payload|
    case payload["kind"]
    when "slow_query"
      internal_telemetry_tables.match?(payload["sql"].to_s) ? nil : payload
    when "performance_issue"
      payload["queue"] == ingest_queue ? nil : payload
    else
      payload
    end
  end

  config.slow_query_threshold_ms = 250
  config.capture_handled_errors = true
  config.report_active_job_errors = true
  config.capture_rails_logs = true
  config.capture_rails_logs_min_level = :warn
  config.detect_performance_issues = false

  config.send_pii = false
  config.capture_request_body = false
  config.capture_query_bindings = false
  config.capture_method_arguments = false
  config.filter_parameters = Rails.application.config.filter_parameters
end
