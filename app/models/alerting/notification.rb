# frozen_string_literal: true

module Alerting
  # Notifica recapitata (ledger): alimenta il notification center in-app + audit + dedup/throttle.
  # title/body sono uno SNAPSHOT umano (renderizza anche se il subject cambia, come Ticketing::Event).
  # subject è polimorfico: Errors::Group o Uptime::Incident. dedup_key + unique [rule_id, dedup_key]
  # = anti-spam (un burst sullo stesso subject nella finestra → 1 sola notifica per destinatario).
  class Notification < ApplicationRecord
    self.table_name = "alerting_notifications"

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :project, class_name: "Projects::Project", optional: true
    belongs_to :account, class_name: "Accounts::Account", optional: true
    belongs_to :rule, class_name: "Alerting::Rule", optional: true
    belongs_to :subject, polymorphic: true

    # Valori APPESI (mai riordinare): telegram (2) è il canale DM per-utente (bot ufficiale), gemello
    # dell'email. Ogni canale consegnato = una riga distinta (dedup_key include il via → no collisione).
    enum :via, { in_app: 0, email: 1, telegram: 2 }, prefix: :via
    # Valori APPESI (mai riordinare): i ticket_* (5-10) entrano nello stesso ledger con rule_id = nil
    # e subject = Ticketing::Ticket. Alerting::Rule resta monitoring-only (errors/uptime/metric).
    enum :event_type, {
      error_new: 0, error_regression: 1, uptime_down: 2, uptime_up: 3, metric_threshold: 4,
      ticket_created: 5, ticket_assigned: 6, ticket_status_changed: 7,
      ticket_milestone_changed: 8, ticket_commented: 9, ticket_mentioned: 10,
      ticket_review_requested: 11,
      # Chat: subject = Chat::Message, rule_id = nil (come i ticket_*). Valori APPESI (mai riordinare):
      # l'11 è di ticket_review_requested (già in prod) → la chat parte da 12.
      chat_message: 12, chat_mentioned: 13,
      uptime_ssl_expiring: 14, cron_missed: 15,
      # Server monitoring: subject = Servers::Host, project nil (org-scoped). Valori APPESI (il 15 è
      # di cron_missed).
      server_down: 16, server_up: 17, server_cpu: 18, server_mem: 19, server_disk: 20,
      server_temp: 21, server_service_failed: 22, server_smart_failing: 23,
      # Decisioni di review sui ticket (rejected pinga l'assignee col motivo). Valori APPESI
      # (il 23 è di server_smart_failing).
      ticket_review_rejected: 24, ticket_review_approved: 25,
      # Spike/surge di un errore già unresolved (subject = Errors::Group, come error_new/regression).
      # Valore APPESO (il 25 è ticket_review_approved).
      error_spike: 26,
      # Log error/fatal (subject = Logs::Entry, rule_id valorizzato: passa da Alerting::Rule come gli
      # errori). Valore APPESO (il 26 è error_spike).
      log_alert: 27,
      # Rotazione secret in scadenza (CYRA-138, Fase 4 pezzo A2): subject = Secrets::Variable, rule_id
      # nil (dispatch diretto come i ticket_*/chat_*, non passa da Alerting::Rule). Valore APPESO
      # (il 27 è log_alert).
      secret_rotation_due: 28,
      # Cancellazione di un secret / sync GitHub fallito (CYRA-138, Fase 4 pezzo B): subject = il
      # PROGETTO (Projects::Project), non più la variabile — per secret_deleted la variabile è già
      # distrutta al momento della notifica, per secret_sync_failed non c'è alcuna variabile coinvolta.
      # rule_id nil (dispatch diretto, come secret_rotation_due). Valori APPESI (il 28 è
      # secret_rotation_due), mai riordinare.
      secret_deleted: 29,
      secret_sync_failed: 30,
      # Approvazione a due per le modifiche ai secret protetti (CYRA-138, Fase 4 pezzo C2c): subject =
      # il PROGETTO (come gli altri secret_*), rule_id nil (dispatch diretto). `requested` va agli
      # approvatori (Alerting::Recipients.for_secrets, escluso il richiedente); `approved`/`rejected`
      # vanno SOLO al richiedente. Valori APPESI (il 30 è secret_sync_failed), mai riordinare.
      secret_change_requested: 31,
      secret_change_approved: 32,
      secret_change_rejected: 33,
      # Database sull'host (CYRA-181): subject = Servers::Host, project nil (org-scoped) come gli
      # altri server_*. Valori APPESI (il 33 è secret_change_rejected), mai riordinare.
      server_db_down: 34,
      server_db_connections: 35,
      server_replication_lag: 36,
      # Agenti di automazione (CYRA-212): il sistema gira a vuoto — host attivi che chiudono lavorazioni
      # senza mai concluderne una con successo. Org-scoped (subject = Organizations::Organization, project
      # nil come i server_*), rule_id valorizzato: passa da Alerting::Rule come gli altri allarmi
      # monitoring. Valore APPESO (il 36 è server_replication_lag), mai riordinare.
      agents_stalled: 37,
      # Container spariti fra due push (CYRA-248): subject = Servers::Host, project nil (org-scoped)
      # come gli altri server_*, rule_id valorizzato (passa da Alerting::Rule). Valore APPESO (il 37
      # è agents_stalled), mai riordinare.
      server_container_down: 38,
      # Una macchina di automazione butta via il lavoro (CYRA-282): subject = Agents::Host, project nil
      # (org-scoped), rule_id valorizzato (passa da Alerting::Rule come agents_stalled). Valore APPESO
      # (il 38 è server_container_down), mai riordinare.
      agents_host_failing: 39,
      # Risposta lenta oltre soglia (CYRA-151): subject = Uptime::Monitor (come uptime_ssl_expiring),
      # rule_id valorizzato (passa da Alerting::Rule). Valore APPESO (il 39 è agents_host_failing),
      # mai riordinare.
      uptime_slow: 40,
      # Traffico del sito (CYRA-147): crollo o picco anomalo delle visite, rilevato da un detector
      # periodico che confronta la finestra corrente con la baseline. subject = Projects::Project (il
      # traffico è per progetto, nessun modello incident), rule_id valorizzato (passa da Alerting::Rule
      # come gli altri monitoring). Valori APPESI (il 40 è uptime_slow), mai riordinare.
      analytics_traffic_drop: 41,
      analytics_traffic_spike: 42,
      # Idee (CYRA-147): nuova idea in un progetto e nuovo commento a un'idea. subject = Ideas::Idea /
      # Ideas::Comment, project valorizzato, rule_id valorizzato (passa da Alerting::Rule; l'autore è
      # escluso dai destinatari via actor_id). Valori APPESI (il 42 è analytics_traffic_spike).
      idea_created: 43,
      idea_commented: 44,
      # Attività di carico di lavoro in scadenza (CYRA-147): promemoria su una Workload::Action ancora
      # aperta con la scadenza imminente o superata. subject = Workload::Action, project nil (team-scoped:
      # org da action.team, destinatari = partecipanti), rule_id valorizzato. Valore APPESO (il 44 è
      # idea_commented).
      workload_due_soon: 45,
      # Addestramento di un dataset finito o fallito (CYRA-147): subject = Datasets::Training, project
      # valorizzato (via training.dataset.project), rule_id valorizzato. Valori APPESI (il 45 è
      # workload_due_soon), mai riordinare.
      dataset_training_completed: 46,
      dataset_training_failed: 47,
      # Una macchina di automazione è ferma (CYRA-450): subject = Agents::Host, project nil (org-scoped),
      # rule_id valorizzato (passa da Alerting::Rule come agents_host_failing). Senza questo valore la
      # consegna in-app (Notifications::Deliver) esploderebbe creando la riga. Valore APPESO (il 47 è
      # dataset_training_failed), mai riordinare.
      agents_host_stale: 48,
      # Vulnerabilità di una dipendenza e runtime fuori supporto (CYRA-506): subject =
      # Vulnerabilities::Finding / Vulnerabilities::RuntimeStatus, project valorizzato, rule_id
      # valorizzato (passano entrambi da Alerting::Rule). Valori APPESI (il 48 è agents_host_stale),
      # mai riordinare.
      vulnerability_new: 49,
      runtime_eol: 50,
      # Servizio di embedding irraggiungibile (CYEM-2): ricerca semantica, collegamenti e deduplica
      # smettono di funzionare senza dirlo a nessuno. Org-scoped (subject = Organizations::Organization,
      # project nil come i server_*), rule_id valorizzato: passa da Alerting::Rule. Valore APPESO
      # (il 50 e' runtime_eol): la PR era nata con 38, preso da server_container_down nel frattempo.
      embedding_down: 51,
      # Container tornati su (CYRA-512): subject = Servers::Host, project nil (org-scoped) come gli
      # altri server_*, rule_id valorizzato. Gemello di server_up per server_container_down. Valore
      # APPESO (il 51 è embedding_down), mai riordinare.
      server_container_up: 52,
      # Capacità e transizioni infrastrutturali (CYRA-515), append-only dopo server_container_up.
      server_db_connection_usage: 53,
      server_data_volume_disk: 54,
      server_inode: 55,
      server_replication_down: 56,
      server_replication_up: 57,
      server_container_restart_loop: 58,
      server_container_stable: 59,
      # Rilievo SEO nuovo (CYRA-528): subject = Seo::Issue, project valorizzato, rule_id
      # valorizzato (passa da Alerting::Rule). Valore APPESO (il 59 è server_container_stable).
      seo_issue_new: 60,
      # Accesso a un segreto (CYRA-77): subject = Secrets::Event (la riga d'audit stessa, che è
      # append-only → lo snapshot resta veritiero per sempre), project valorizzato, rule_id
      # valorizzato (passa da Alerting::Rule, a differenza dei secret_* di dispatch diretto qui
      # sopra). Valori APPESI (il 60 è seo_issue_new), mai riordinare.
      secret_read: 61,
      secret_denied: 62,
      # CYRA-676: aggiornamenti di sicurezza pendenti e dati fermi (subject = Servers::Host,
      # org-scoped come gli altri server_*). Valori APPESI (il 62 è secret_denied).
      server_security_updates: 63,
      server_silent: 64,
      # CYRA-679: previsione di saturazione del volume dati (subject = Servers::Host, org-scoped).
      # Valore APPESO (il 64 è server_silent).
      server_disk_forecast: 65,
      # CYRA-712: il servizio generativo non risponde alla chiave dell'organizzazione, e il rientro.
      # Org-scoped (subject = Organizations::Organization, project nil come embedding_down), rule_id
      # valorizzato: passano da Alerting::Rule. Valori APPESI (il 65 è server_disk_forecast).
      ai_unavailable: 66,
      ai_available: 67,
      # CYRA-716: una credenziale di ingest di progetto sta per scadere o è già scaduta. subject =
      # Projects::Token, project valorizzato, rule_id nil (dispatch diretto, come secret_rotation_due:
      # non nasce da un allarme configurabile ma da un giro giornaliero sulle date). Valore APPESO
      # (il 67 è ai_available), mai riordinare.
      project_token_expiring: 68,
      # CYRA-775: il backend ha respinto i dati delle sonde (subject = Organizations::Organization,
      # project nil come gli altri server_*), rule_id valorizzato — passa da Alerting::Rule. Valore
      # APPESO (il 68 è project_token_expiring), mai riordinare.
      server_ingest_rejected: 69,
      # CYRA-777: lo stesso valore segreto è stato ricopiato in più progetti e c'è una proposta di
      # spostarlo nei secret dell'organizzazione. subject = Secrets::Consolidation::Suggestion (la
      # proposta stessa: sopravvive alla decisione e porta lo stato), project nil — un valore in
      # comune per definizione non è di un progetto solo — rule_id nil (dispatch diretto, come
      # secret_rotation_due: non nasce da un allarme configurabile ma dal giro sulle impronte).
      # Valore APPESO (il 69 è server_ingest_rejected), mai riordinare.
      secret_consolidation_suggested: 70,
      # Domande e risposte sui ticket (CYRA-782): subject = Ticketing::Ticket, rule_id nil, come
      # gli altri ticket_*. Valori APPESI (il 70 è secret_consolidation_suggested).
      ticket_question_asked: 71,
      ticket_question_answered: 72,
      # CYRA-846: la memoria temporanea condivisa non risponde (subject =
      # Organizations::Organization, project nil come embedding_down), rule_id valorizzato —
      # passa da Alerting::Rule. Valore APPESO (il 72 è ticket_question_answered).
      cache_unavailable: 73,
      # CYAG-22: Kubernetes cluster alerts, rule_id set (they go through Alerting::Rule). Values
      # APPENDED (73 is cache_unavailable).
      cluster_down: 74,
      cluster_up: 75,
      cluster_node_not_ready: 76,
      cluster_node_pressure: 77,
      cluster_workload_crashloop: 78,
      cluster_workload_degraded: 79,
      measurement_threshold: 80
    }, prefix: :event
    # Valori APPESI (mai riordinare): queued (4) = email/telegram trattenuta per il digest (cadenza
    # daily/weekly), raccolta e marcata :sent dal job digest (digest_bucket dice a quale ciclo appartiene).
    # held (5) = email immediata trattenuta dalle quiet hours (CYRA-208): NON è :skipped (definitivo,
    # persa) ma in attesa della prima finestra utile, quando Notifications::ReleaseHeldJob la consegna
    # in un riepilogo e la marca :sent. Solo email: in-app/telegram non hanno quiet hours.
    enum :status, { pending: 0, sent: 1, failed: 2, skipped: 3, queued: 4, held: 5 }, prefix: :status
    # Nullo sulle righe immediate/in-app; :daily/:weekly sulle righe :queued.
    enum :digest_bucket, { daily: 0, weekly: 1 }, prefix: :digest_bucket

    validates :title, presence: true
    validates :dedup_key, presence: true, uniqueness: { scope: :rule_id }

    scope :unread, -> { where(read_at: nil) }
    scope :recent, -> { order(created_at: :desc) }

    def read? = read_at.present?

    # The link is composed from the subject when read, so renamed pages never strand old
    # notifications. The stored path is the fallback when the subject is gone.
    def url = Notifications::Link.for(self) || super

    def mark_read!
      return if read?
      update!(read_at: Time.current)
    end
  end
end
