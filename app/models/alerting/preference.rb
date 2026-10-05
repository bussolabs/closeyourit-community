# frozen_string_literal: true

module Alerting
  # Preferenze di notifica PERSONALI, per organizzazione: canali (in-app/email), sorgenti
  # (errors/uptime), livello minimo errori, quiet hours (le email vengono trattenute, l'in-app no).
  # Chi non ha un record usa il default "tutto abilitato" via .for (non persistito).
  class Preference < ApplicationRecord
    self.table_name = "alerting_preferences"

    # Coercizione nome→intero + validazione di min_level, condivisa con Alerting::Rule (CYRA-236).
    include MinLevelCoercible

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :account, class_name: "Accounts::Account"

    enum :digest, { off: 0, hourly: 1, daily: 2 }, prefix: :digest

    # Riepilogo periodico dei DATI (CYRA-160): non è un avviso — non nasce da un evento, parte a
    # calendario. Valori APPESI (mai riordinare). OFF di default: è un'email in più, la si riceve
    # perché la si è chiesta.
    enum :report_cadence, { off: 0, daily: 1, weekly: 2, monthly: 3 }, prefix: :report_cadence

    # Quanto lontano guarda indietro il riepilogo, per frequenza. Sono le stesse chiavi di finestra
    # dei grafici (Analytics::Pageview::BUCKETS, Uptime::Monitor::RANGES): il numero nell'email e
    # quello nella pagina rispondono alla stessa domanda e devono coincidere.
    REPORT_RANGES = { "daily" => "24h", "weekly" => "7d", "monthly" => "30d" }.freeze

    validates :account_id, uniqueness: { scope: :organization_id }

    # Preferenza persistita per la coppia, o un default in-memory (tutto abilitato).
    def self.for(account:, organization:)
      find_by(account_id: account.id, organization_id: organization.id) ||
        new(account: account, organization: organization)
    end

    # La sorgente di questo tipo di evento è abilitata per l'utente?
    def source_enabled?(event_type)
      case event_type.to_s
      when "error_new", "error_regression", "error_spike" then errors_enabled?
      when "uptime_down", "uptime_up", "uptime_slow", "uptime_ssl_expiring", "cron_missed" then uptime_enabled?
      when "metric_threshold", "measurement_threshold" then performance_enabled?
      when "ticket_created", "ticket_assigned", "ticket_status_changed",
           "ticket_milestone_changed", "ticket_commented", "ticket_mentioned",
           "ticket_review_requested", "ticket_review_rejected", "ticket_review_approved",
           "ticket_question_asked", "ticket_question_answered" then tickets_enabled?
      when "chat_message", "chat_mentioned" then chat_enabled?
      when "server_down", "server_up", "server_cpu", "server_mem", "server_disk",
           "server_temp", "server_service_failed", "server_smart_failing",
           "server_db_down", "server_db_connections", "server_db_connection_usage",
           "server_replication_lag", "server_replication_down", "server_replication_up",
           "server_data_volume_disk", "server_inode", "server_container_down", "server_container_up",
           "server_container_restart_loop", "server_container_stable",
           # CYRA-775: i dati delle sonde respinti dal backend. Sta con gli altri server_* perché è
           # una notizia sul monitoraggio delle macchine — chi ha spento quella sorgente non la vuole.
           "server_ingest_rejected",
           # CYAG-22: Kubernetes clusters belong to the same infrastructure source as the servers.
           "cluster_down", "cluster_up", "cluster_node_not_ready", "cluster_node_pressure",
           "cluster_workload_crashloop", "cluster_workload_degraded" then servers_enabled?
      # Allarmi di salute dell'automazione (CYRA-212 org bloccata, CYRA-282 host che butta via il lavoro,
      # CYRA-450 host fermo): non hanno un interruttore di sorgente dedicato — la consegna resta governata
      # dai canali email/telegram per-utente come gli altri eventi.
      when "agents_stalled", "agents_host_failing", "agents_host_stale" then true
      # Vulnerabilità e runtime fuori supporto (CYRA-506): sicurezza delle dipendenze. Non hanno un
      # interruttore di sorgente dedicato — la consegna resta governata dai canali per-utente.
      when "vulnerability_new", "runtime_eol" then true
      # Rilievo SEO (CYRA-528): come le vulnerabilità, nessun interruttore di sorgente dedicato.
      when "seo_issue_new" then true
      # Servizio di embedding giu' (CYEM-2): come agents_stalled, nessun interruttore di sorgente
      # dedicato — la consegna resta governata dai canali email/telegram per-utente.
      when "embedding_down" then true
      # Servizio generativo giù e rientro (CYRA-712): come embedding_down, nessun interruttore di
      # sorgente dedicato — la consegna resta governata dai canali email/telegram per-utente.
      when "ai_unavailable", "ai_available" then true
      # Memoria temporanea giù (CYRA-846): come embedding_down, nessun interruttore di sorgente
      # dedicato — la consegna resta governata dai canali email/telegram per-utente.
      when "cache_unavailable" then true
      else false # tipi ignoti
      end
    end

    # Cadenza email per l'evento: off se il canale email è spento (interruttore globale per la coppia),
    # altrimenti il valore salvato o il default di canale (immediata).
    def email_cadence_for(event_type)
      return Notifications::Cadence::OFF unless email_enabled?

      cadence_from(email_cadences, event_type, Notifications::Cadence::DEFAULT_EMAIL)
    end

    # Cadenza Telegram per l'evento: off se il canale è spento (interruttore globale per la coppia),
    # altrimenti il valore salvato o il default di canale (off).
    def telegram_cadence_for(event_type)
      return Notifications::Cadence::OFF unless telegram_enabled?

      cadence_from(telegram_cadences, event_type, Notifications::Cadence::DEFAULT_TELEGRAM)
    end

    def cadence_for(event_type, channel)
      case channel.to_sym
      when :email    then email_cadence_for(event_type)
      when :telegram then telegram_cadence_for(event_type)
      else Notifications::Cadence::OFF
      end
    end

    # Decisione per-canale al dispatch. connected_telegram = account.connected_telegram? (passato dal
    # chiamante per non ricaricare l'account). Per ogni canale: deliver? (creare una notifica?) e bucket
    # (nil = immediata; :daily/:weekly = trattenuta per il digest). L'in-app NON passa di qui: è sempre
    # consegnata. Telegram richiede canale acceso + account collegato.
    def channels_for(event_type, connected_telegram: false)
      {
        email: decision_for(email_cadence_for(event_type)),
        telegram: telegram_decision_for(event_type, connected_telegram: connected_telegram)
      }
    end

    # Cadenza SALVATA per la UI (valore memorizzato o default): mostra la scelta dell'utente a
    # prescindere dal toggle globale del canale (che governa solo la consegna, non il valore mostrato).
    def stored_email_cadence(event_type)
      cadence_from(email_cadences, event_type, Notifications::Cadence::DEFAULT_EMAIL)
    end

    def stored_telegram_cadence(event_type)
      cadence_from(telegram_cadences, event_type, Notifications::Cadence::DEFAULT_TELEGRAM)
    end

    # Avvisi su cui l'utente ha fatto una scelta esplicita, su uno dei due canali (CYRA-443). Serve
    # alla pagina preferenze per aprire i gruppi PERTINENTI invece di tutti. Filtra sul catalogo:
    # un event_type rimosso dal codice resta nel jsonb ma non ha più una riga da aprire.
    def customized_event_types
      stored = (email_cadences.presence || {}).keys + (telegram_cadences.presence || {}).keys
      stored.uniq & Notifications::Catalog.event_types
    end

    # Il riepilogo dei dati è un'email: chi ha spento le email l'ha spento anche lui. Un canale
    # spento che continua a scrivere è peggio di un canale muto — nessuno va a cercarlo lì.
    def report_enabled? = email_enabled? && !report_cadence_off?

    # Finestra di dati da riassumere ("24h"/"7d"/"30d"), nil se il riepilogo è spento.
    def report_range = REPORT_RANGES[report_cadence]

    # Il riepilogo di questo periodo è ancora da spedire? Il giro ricorrente gira ogni giorno e
    # domanda a ognuno: la risposta è sì una volta per periodo (giorno / settimana da lunedì / mese),
    # e la data dell'ultimo invio è ciò che impedisce il doppione. Chi accende la frequenza a metà
    # settimana riceve il primo riepilogo al primo giro utile — poi si aggancia al lunedì, perché da
    # lì in avanti l'ultimo invio cade dentro il periodo corrente.
    def report_due?(now = Time.current)
      return false unless report_enabled?

      report_last_sent_at.nil? || report_last_sent_at < report_period_start(now)
    end

    # Siamo nelle ore silenziose (range eventualmente notturno con wrap)?
    def quiet_now?(at: Time.current)
      return false if quiet_hours_start.nil? || quiet_hours_end.nil?
      return false if quiet_hours_start == quiet_hours_end

      zone = quiet_hours_tz.presence || Time.zone.name
      hour = at.in_time_zone(zone).hour
      if quiet_hours_start < quiet_hours_end
        hour >= quiet_hours_start && hour < quiet_hours_end
      else
        hour >= quiet_hours_start || hour < quiet_hours_end
      end
    end

    private

    # Inizio del periodo corrente per la frequenza scelta: la settimana comincia di lunedì (default
    # di Rails), il mese il primo giorno. Un invio precedente a questo istante è di un altro periodo.
    def report_period_start(now)
      case report_cadence
      when "daily"  then now.beginning_of_day
      when "weekly" then now.beginning_of_week
      else               now.beginning_of_month
      end
    end

    def cadence_from(map, event_type, default)
      value = map&.dig(event_type.to_s)
      Notifications::Cadence.valid?(value) ? value : default
    end

    def decision_for(cadence)
      case cadence
      when Notifications::Cadence::IMMEDIATE then { deliver: true, bucket: nil }
      when Notifications::Cadence::DAILY     then { deliver: true, bucket: :daily }
      when Notifications::Cadence::WEEKLY    then { deliver: true, bucket: :weekly }
      else { deliver: false, bucket: nil } # off / ignoto
      end
    end

    # Raggiungibile su Telegram: chat personale collegata, o gruppo con argomenti dell'owner (CYRA-852).
    def telegram_decision_for(event_type, connected_telegram:)
      reachable = connected_telegram || Alerting::TelegramGroup.for_recipient(account: account, organization: organization)
      return { deliver: false, bucket: nil } unless telegram_enabled? && reachable

      decision_for(telegram_cadence_for(event_type))
    end
  end
end
