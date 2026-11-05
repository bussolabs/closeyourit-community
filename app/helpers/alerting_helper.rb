# frozen_string_literal: true

# Mappa il tipo di evento alerting a icona + tono colore (palette Tailwind nativa) per le notifiche.
module AlertingHelper
  # CYRA-480 — UN nome solo per ogni evento. Le regole e le impostazioni personali avevano due
  # cataloghi sovrapposti con parole diverse per la stessa cosa («Cron mancato» / «Job schedulato
  # mancato», «Uptime up» / «Uptime ripristinato», «CPU server oltre soglia» / «CPU alta»): chi
  # leggeva le due pagine non poteva sapere che parlavano dello stesso evento. La fonte unica è
  # Notifications::Catalog, che ha anche le descrizioni — il miglior glossario del dominio.
  # Il fallback serve solo a un event_type fuori catalogo: non deve mai far esplodere una pagina.
  def alerting_event_label(event_type)
    ::Notifications::Catalog.entry(event_type)&.title ||
      t("member.alerting.event_types.#{event_type}", default: event_type.to_s.humanize)
  end

  def alerting_event_description(event_type)
    ::Notifications::Catalog.entry(event_type)&.description
  end

  EVENT_TONES = {
    "error_new" => { icon: "bug", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    "error_regression" => { icon: "rotate-ccw", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "error_spike" => { icon: "trending-up", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    "uptime_down" => { icon: "heart-crack", bg: "bg-rose-50 dark:bg-rose-500/15", fg: "text-rose-600 dark:text-rose-400" },
    "uptime_up" => { icon: "heart-pulse", bg: "bg-emerald-50 dark:bg-emerald-500/15", fg: "text-emerald-700 dark:text-emerald-300" },
    "uptime_slow" => { icon: "gauge", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "ticket_created" => { icon: "circle-plus", bg: "bg-indigo-50 dark:bg-indigo-500/15", fg: "text-indigo-600 dark:text-indigo-400" },
    "ticket_assigned" => { icon: "user-check", bg: "bg-sky-50 dark:bg-sky-500/15", fg: "text-sky-600 dark:text-sky-400" },
    "ticket_status_changed" => { icon: "refresh-cw", bg: "bg-violet-50 dark:bg-violet-500/15", fg: "text-violet-600 dark:text-violet-400" },
    "ticket_milestone_changed" => { icon: "flag", bg: "bg-teal-50 dark:bg-teal-500/15", fg: "text-teal-600 dark:text-teal-400" },
    "ticket_commented" => { icon: "message-circle", bg: "bg-stone-100 dark:bg-zinc-800", fg: "text-gray-600 dark:text-zinc-400" },
    "ticket_mentioned" => { icon: "at-sign", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "chat_message" => { icon: "messages-square", bg: "bg-sky-50 dark:bg-sky-500/15", fg: "text-sky-600 dark:text-sky-400" },
    "chat_mentioned" => { icon: "at-sign", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "ticket_review_rejected" => { icon: "rotate-ccw", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    "ticket_review_approved" => { icon: "circle-check", bg: "bg-emerald-50 dark:bg-emerald-500/15", fg: "text-emerald-700 dark:text-emerald-300" },
    "ticket_question_asked" => { icon: "circle-question-mark", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "ticket_question_answered" => { icon: "reply", bg: "bg-sky-50 dark:bg-sky-500/15", fg: "text-sky-700 dark:text-sky-300" },
    "ticket_review_requested" => { icon: "clipboard-check", bg: "bg-indigo-50 dark:bg-indigo-500/15", fg: "text-indigo-600 dark:text-indigo-400" },
    "metric_threshold" => { icon: "gauge", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "log_alert" => { icon: "file-text", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    "uptime_ssl_expiring" => { icon: "lock", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "cron_missed" => { icon: "clock", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "server_down" => { icon: "server", bg: "bg-rose-50 dark:bg-rose-500/15", fg: "text-rose-600 dark:text-rose-400" },
    "server_up" => { icon: "server", bg: "bg-emerald-50 dark:bg-emerald-500/15", fg: "text-emerald-700 dark:text-emerald-300" },
    "server_cpu" => { icon: "microchip", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "server_mem" => { icon: "memory-stick", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "server_disk" => { icon: "hard-drive", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "server_temp" => { icon: "thermometer", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "server_service_failed" => { icon: "cog", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    "server_smart_failing" => { icon: "triangle-alert", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    # Container caduto/sparito dal push (CYRA-248): tono attenzione come gli altri guasti server.
    "server_container_down" => { icon: "box", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    # Container tornati su (CYRA-512): tono rassicurante, come server_up rispetto a server_down.
    "server_container_up" => { icon: "box", bg: "bg-emerald-50 dark:bg-emerald-500/15", fg: "text-emerald-700 dark:text-emerald-300" },
    "server_container_restart_loop" => { icon: "refresh-cw", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    "server_container_stable" => { icon: "circle-check", bg: "bg-emerald-50 dark:bg-emerald-500/15", fg: "text-emerald-700 dark:text-emerald-300" },
    "server_db_connection_usage" => { icon: "database", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "server_data_volume_disk" => { icon: "hard-drive", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "server_inode" => { icon: "folder-tree", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "server_replication_down" => { icon: "unlink", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    "server_replication_up" => { icon: "link", bg: "bg-emerald-50 dark:bg-emerald-500/15", fg: "text-emerald-700 dark:text-emerald-300" },
    "secret_rotation_due" => { icon: "key", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "secret_consolidation_suggested" => { icon: "group", bg: "bg-indigo-50 dark:bg-indigo-500/15", fg: "text-indigo-700 dark:text-indigo-300" },
    "secret_deleted" => { icon: "trash", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    "secret_sync_failed" => { icon: "cloud-upload", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    # Approvazione a due (CYRA-138, pezzo C2c): stessi toni della famiglia review dei ticket —
    # requested = neutro/informativo, approved = positivo, rejected = attenzione.
    "secret_change_requested" => { icon: "clipboard-check", bg: "bg-indigo-50 dark:bg-indigo-500/15", fg: "text-indigo-600 dark:text-indigo-400" },
    "secret_change_approved" => { icon: "circle-check", bg: "bg-emerald-50 dark:bg-emerald-500/15", fg: "text-emerald-700 dark:text-emerald-300" },
    "secret_change_rejected" => { icon: "rotate-ccw", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    # Accessi ai segreti (CYRA-77): la lettura è un fatto da sapere (tono informativo), il tentativo
    # bloccato è qualcuno che ha bussato dove non doveva (tono attenzione).
    "secret_read" => { icon: "eye", bg: "bg-indigo-50 dark:bg-indigo-500/15", fg: "text-indigo-600 dark:text-indigo-400" },
    "secret_denied" => { icon: "ban", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    # Credenziale di ingest in scadenza (CYRA-716): stessa chiave della rotazione dei secret — è la
    # stessa notizia ("questa credenziale sta per non valere più") — e tono attenzione.
    "project_token_expiring" => { icon: "key", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    # Agenti di automazione bloccati (CYRA-212): il sistema gira a vuoto — tono attenzione.
    "agents_stalled" => { icon: "bot", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    # Una macchina di automazione butta via il lavoro (CYRA-282): guasto tecnico — tono rosso.
    "agents_host_failing" => { icon: "triangle-alert", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    # Una macchina di automazione è ferma (CYRA-450): non risponde più — tono rosso.
    "agents_host_stale" => { icon: "power-off", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    # Sicurezza delle dipendenze (CYRA-506): scudo per la falla trovata, clessidra per la versione
    # che sta per restare senza patch — due urgenze diverse, due segnali diversi.
    "vulnerability_new" => { icon: "shield-half", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    "runtime_eol" => { icon: "hourglass", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-600 dark:text-amber-400" },
    # Statistiche del sito (CYRA-147): crollo = attenzione, picco = informativo.
    "analytics_traffic_drop" => { icon: "trending-down", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    "analytics_traffic_spike" => { icon: "trending-up", bg: "bg-sky-50 dark:bg-sky-500/15", fg: "text-sky-600 dark:text-sky-400" },
    # Idee (CYRA-147): nuova idea = accento indigo, commento = neutro (come i ticket).
    "idea_created" => { icon: "lightbulb", bg: "bg-indigo-50 dark:bg-indigo-500/15", fg: "text-indigo-600 dark:text-indigo-400" },
    "idea_commented" => { icon: "message-circle", bg: "bg-stone-100 dark:bg-zinc-800", fg: "text-gray-600 dark:text-zinc-400" },
    # Attività in scadenza (CYRA-147): promemoria temporale — tono attenzione.
    "workload_due_soon" => { icon: "clock", bg: "bg-amber-50 dark:bg-amber-500/15", fg: "text-amber-700 dark:text-amber-300" },
    # Dataset (CYRA-147): addestramento completato = positivo, fallito = errore.
    "dataset_training_completed" => { icon: "circle-check", bg: "bg-emerald-50 dark:bg-emerald-500/15", fg: "text-emerald-700 dark:text-emerald-300" },
    "dataset_training_failed" => { icon: "triangle-alert", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    # Servizio di embedding irraggiungibile (CYEM-2): funzioni intere ferme — tono allarme.
    "embedding_down" => { icon: "brain", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    # Servizio generativo (CYRA-712): giù = tono allarme come embedding_down, rientro = positivo
    # come server_up.
    "ai_unavailable" => { icon: "bot", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" },
    "ai_available" => { icon: "bot", bg: "bg-emerald-50 dark:bg-emerald-500/15", fg: "text-emerald-700 dark:text-emerald-300" },
    # Memoria temporanea giù (CYRA-846): gli avvisi esterni possono tacere — tono allarme.
    "cache_unavailable" => { icon: "database", bg: "bg-red-50 dark:bg-red-500/15", fg: "text-red-600 dark:text-red-400" }
  }.freeze

  DEFAULT_TONE = { icon: "bell", bg: "bg-stone-100 dark:bg-zinc-800", fg: "text-gray-500 dark:text-zinc-400" }.freeze

  # ticket_*/chat_* sono conversazioni (attività su ticket, messaggi), non avvisi tecnici (CYRA-323):
  # distinguibili a colpo d'occhio nel notification center senza aprire/leggere il corpo.
  CONVERSATION_PREFIXES = %w[ticket_ chat_].freeze

  def alerting_event_tone(event_type)
    EVENT_TONES.fetch(event_type.to_s, DEFAULT_TONE)
  end

  # Finestra ore silenziose come "HH:MM–HH:MM" (start/end sono ore intere 0-23), o nil se non
  # configurata. Rende visibile nell'header del centro notifiche l'esistenza della finestra che
  # trattiene le email non urgenti (CYRA-479). Una finestra degenere (start == end) è nil: coerente
  # con Alerting::Preference#quiet_now?, che la tratta come ore silenziose DISATTIVATE — mostrare
  # "22:00–22:00" mentre nessuna email viene trattenuta ingannerebbe.
  def alerting_quiet_window(preference)
    from = preference&.quiet_hours_start
    to = preference&.quiet_hours_end
    return nil if from.nil? || to.nil? || from == to

    format("%02d:00–%02d:00", from, to)
  end

  def alerting_conversation?(event_type)
    CONVERSATION_PREFIXES.any? { |prefix| event_type.to_s.start_with?(prefix) }
  end

  # CYRA-488 — evento grave (guasto di produzione) che merita un trattamento visivo distinto nel
  # notification center: così il guasto vero non resta sepolto sotto le ripetizioni. Riusa la criticità
  # già definita nel catalogo (Vocabolario UNICO): niente terza tassonomia, niente environment per riga.
  def alerting_critical?(event_type)
    ::Notifications::Catalog.critical?(event_type)
  end
  # Conteggio notifiche in-app non lette dell'account corrente nell'org corrente (badge topbar).
  def unread_alerts_count
    return 0 unless Current.account && Current.organization

    Alerting::Notification.where(account_id: Current.account.id,
                                 organization_id: Current.organization.id, via: :in_app).unread.count
  end
end
