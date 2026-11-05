# frozen_string_literal: true

module Notifications
  # Emoji per tipo di evento (prima riga del messaggio Telegram) + dominio dell'evento (per la label
  # del link footer, es. "vai al ticket"). Copre tutti gli event_type dell'enum Alerting::Notification;
  # tipo sconosciuto → DEFAULT (🔔). Le emoji sono identiche cross-lingua → mappa Ruby, NON i18n.
  module TelegramEmoji
    DEFAULT = "🔔"

    EMOJI = {
      # ticketing
      "ticket_created" => "🎫",
      "ticket_assigned" => "👤",
      "ticket_status_changed" => "🔄",
      "ticket_milestone_changed" => "🎯",
      "ticket_commented" => "💬",
      "ticket_mentioned" => "📣",
      "ticket_review_requested" => "👀",
      "ticket_review_approved" => "✅",
      "ticket_question_asked" => "❓",
      "ticket_question_answered" => "💬",
      "ticket_review_rejected" => "❌",
      # chat
      "chat_message" => "💬",
      "chat_mentioned" => "📣",
      # errors
      "error_new" => "🐛",
      "error_regression" => "🔁",
      "error_spike" => "🚨",
      # uptime
      "uptime_down" => "🔴",
      "uptime_up" => "🟢",
      "uptime_slow" => "🐌",
      "uptime_ssl_expiring" => "🔒",
      # metric
      "metric_threshold" => "📈",
      "measurement_threshold" => "📈",
      # logs
      "log_alert" => "📋",
      # cron
      "cron_missed" => "⏰",
      # server
      "server_down" => "🔴",
      "server_up" => "🟢",
      "server_cpu" => "🔥",
      "server_mem" => "🧠",
      "server_disk" => "💾",
      "server_temp" => "🌡️",
      "server_service_failed" => "⚠️",
      "server_smart_failing" => "💽",
      # container spariti dal push (CYRA-248) e tornati su (CYRA-512)
      "server_container_down" => "📦",
      "server_container_up" => "📦",
      "server_container_restart_loop" => "🔁",
      "server_container_stable" => "✅",
      # database sull'host (CYRA-181)
      "server_db_down" => "🛑",
      "server_db_connections" => "🔌",
      "server_db_connection_usage" => "📊",
      "server_replication_lag" => "⏳",
      "server_replication_down" => "🔴",
      "server_replication_up" => "🟢",
      "server_data_volume_disk" => "💾",
      "server_inode" => "🗂️",
      "server_security_updates" => "🛡️",
      "server_silent" => "🔇",
      "server_disk_forecast" => "⏳",
      # CYRA-775: i dati delle sonde respinti da noi. Non è un guasto della macchina — il segnale è
      # «frenato», non «rotto».
      "server_ingest_rejected" => "🚦",
      # secrets
      "secret_rotation_due" => "🔑",
      "secret_consolidation_suggested" => "🔑",
      "secret_deleted" => "🗑️",
      "secret_sync_failed" => "⚠️",
      # secrets: approvazione a due (CYRA-138, pezzo C2c) — stessa semantica della review dei ticket.
      "secret_change_requested" => "👀",
      "secret_change_approved" => "✅",
      "secret_change_rejected" => "❌",
      # accessi ai segreti (CYRA-77): il valore aperto e il tentativo fermato
      "secret_read" => "👁️",
      "secret_denied" => "🚫",
      # agenti di automazione (CYRA-212 org ferma, CYRA-282 host che butta via il lavoro, CYRA-450 host fermo)
      "agents_stalled" => "🤖",
      "agents_host_failing" => "💥",
      "agents_host_stale" => "💤",
      # CYRA-506 — sicurezza delle dipendenze: scudo per la falla trovata, clessidra per la
      # versione di linguaggio che sta per restare senza patch.
      "vulnerability_new" => "🛡️",
      "runtime_eol" => "⌛",
      # CYRA-528 — SEO: la lente, la stessa dell icona di menu.
      "seo_issue_new" => "🔎",
      # statistiche del sito (CYRA-147)
      "analytics_traffic_drop" => "📉",
      "analytics_traffic_spike" => "📈",
      # idee (CYRA-147)
      "idea_created" => "💡",
      "idea_commented" => "💬",
      # attività da fare / carico di lavoro (CYRA-147)
      "workload_due_soon" => "📅",
      # dataset (CYRA-147)
      "dataset_training_completed" => "🎓",
      "dataset_training_failed" => "❌",
      # servizi interni irraggiungibili (CYEM-2)
      "embedding_down" => "🧠",
      # servizio generativo (CYRA-712): giù = allarme, rientro = tono rassicurante come server_up
      "ai_unavailable" => "🤖",
      "ai_available" => "🟢",
      # memoria temporanea condivisa giù (CYRA-846): i freni anti-doppione degli avvisi tacciono
      "cache_unavailable" => "🗄️",
      # CYAG-22: Kubernetes clusters, same tones as the server alerts.
      "cluster_down" => "🔴",
      "cluster_up" => "🟢",
      "cluster_node_not_ready" => "🟠",
      "cluster_node_pressure" => "🟠",
      "cluster_workload_crashloop" => "🔁",
      "cluster_workload_degraded" => "🟡",
      # credenziale di ingest in scadenza (CYRA-716): la stessa chiave della rotazione dei secret
      "project_token_expiring" => "🔑",
      # a Puck waits for a decision (CYRA-1020)
      "puck_decision_needed" => "🙋",
      "puck_report_ready" => "📋"
    }.freeze

    # Prefisso dell'event_type → dominio, per scegliere la label del link footer (i18n).
    DOMAIN = {
      "ticket" => :ticket,
      "chat" => :chat,
      "error" => :error,
      "log" => :log,
      "uptime" => :uptime,
      "metric" => :metric,
      "measurement" => :metric,
      "cron" => :cron,
      "server" => :server,
      "cluster" => :server,
      "secret" => :secret,
      "agents" => :agents,
      # CYRA-147: statistiche, idee, attività, dataset
      "analytics" => :analytics,
      "seo" => :seo,
      "idea" => :idea,
      "workload" => :workload,
      "dataset" => :dataset,
      # CYRA-506: il prefisso è la prima parola dell'event_type — "vulnerability_new" e
      # "runtime_eol" ne hanno due diversi, quindi due voci per lo stesso dominio.
      "vulnerability" => :vulnerability,
      "runtime" => :vulnerability,
      # servizi interni (CYEM-2): il footer punta agli host di automazione come agents_stalled
      "embedding" => :agents,
      # servizio generativo (CYRA-712): il footer porta ai servizi collegati, che è dove si rimette
      # a posto la chiave — non agli agenti, dove non c'è niente da fare
      "ai" => :ai,
      # memoria temporanea giù (CYRA-846): il footer porta alla flotta, dove si vede quale macchina
      # è caduta
      "cache" => :server,
      "puck" => :puck,
      # CYRA-716: il footer di project_token_expiring porta ai token del progetto, dove si emette la
      # credenziale nuova. È l'unico event_type col prefisso "project".
      "project" => :project_token
    }.freeze

    def self.for(event_type)
      EMOJI.fetch(event_type.to_s, DEFAULT)
    end

    def self.domain_for(event_type)
      DOMAIN.fetch(event_type.to_s.split("_").first, :ticket)
    end
  end
end
