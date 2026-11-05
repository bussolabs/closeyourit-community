# frozen_string_literal: true

module Notifications
  # Catalogo delle notifiche configurabili dall'utente: i 28 event_type di Alerting::Notification
  # raggruppati per dominio, con titolo + descrizione (i18n) e icona/tono per la UI. È un registry
  # COSTANTE dev-defined (eccezione enum-static di rules/lookup-tables.md: aggiungere una notifica =
  # nuovo event_type + codice). Fonte unica dell'elenco per la pagina preferenze e i digest.
  # I valori/nomi degli event_type devono restare allineati all'enum Alerting::Notification#event_type
  # (garantito dallo spec di completezza).
  class Catalog
    # Ordine dei gruppi = ordine di resa nella pagina preferenze (i domini "umani" — ticket/chat —
    # per primi, poi il monitoring). Ogni event_type compare in UN solo gruppo.
    GROUPS = [
      { key: :tickets, events: %w[
        ticket_created ticket_assigned ticket_status_changed ticket_milestone_changed
        ticket_commented ticket_mentioned ticket_review_requested ticket_review_rejected ticket_review_approved
        ticket_question_asked ticket_question_answered
      ] },
      { key: :chat, events: %w[chat_message chat_mentioned] },
      { key: :errors, events: %w[error_new error_regression error_spike] },
      { key: :logs, events: %w[log_alert] },
      { key: :performance, events: %w[metric_threshold measurement_threshold] },
      { key: :uptime, events: %w[uptime_down uptime_up uptime_slow uptime_ssl_expiring] },
      { key: :crons, events: %w[cron_missed] },
      # Il database rilevato sull'host (CYRA-181) resta nel gruppo :servers: è una proprietà
      # dell'host monitorato, non un dominio a sé.
      { key: :servers, events: %w[
        server_down server_up server_cpu server_mem server_disk server_temp server_service_failed
        server_smart_failing server_container_down server_container_up
        server_container_restart_loop server_container_stable
        server_db_down server_db_connections server_db_connection_usage server_replication_lag
        server_replication_down server_replication_up server_data_volume_disk server_inode
        server_security_updates server_silent server_disk_forecast
        server_ingest_rejected
        cluster_down cluster_up cluster_node_not_ready cluster_node_pressure
        cluster_workload_crashloop cluster_workload_degraded
      ] },
      # Vault (CYRA-138, Fase 4): promemoria di rotazione (pezzo A2) + cancellazione secret e sync
      # GitHub fallito (pezzo B) + approvazione a due delle richieste di modifica (pezzo C2c), stesso
      # gruppo :secrets.
      # CYRA-77 aggiunge gli ACCESSI (secret_read/secret_denied): qualcuno ha aperto un valore, o ha
      # provato ad aprirne uno che non gli spetta. Stesso gruppo — chi segue il vault segue entrambe
      # le cose — ma a differenza degli altri secret_* passano da una regola, non da un dispatch diretto.
      { key: :secrets, events: %w[
        secret_rotation_due secret_deleted secret_sync_failed
        secret_change_requested secret_change_approved secret_change_rejected
        secret_read secret_denied secret_consolidation_suggested
      ] },
      # Credenziali di ingest dei progetti (CYRA-716): la chiave che un'applicazione usa per mandare
      # errori e segnali sta per scadere. Gruppo proprio e non dentro :secrets — i destinatari sono
      # chi ha tokens.manage sul progetto, non chi tiene il vault: sono due mestieri diversi.
      { key: :tokens, events: %w[project_token_expiring] },
      # Agenti di automazione (CYRA-212, CYRA-282, CYRA-450): allarmi operativi sul sistema che esegue le
      # lavorazioni — l'org che gira a vuoto, la macchina che butta via il lavoro e quella ferma.
      # CYRA-1020 adds the Puck waiting for a person: Puckies are agents too.
      { key: :agents, events: %w[agents_stalled agents_host_failing agents_host_stale puck_decision_needed puck_report_ready] },
      # Sicurezza delle dipendenze (CYRA-506): la falla trovata in una libreria e la versione di
      # linguaggio che non riceve più patch. Gruppo proprio: chi le riceve non è chi segue le macchine.
      { key: :vulnerabilities, events: %w[vulnerability_new runtime_eol] },
      # Statistiche del sito (CYRA-147): crollo o picco anomalo del traffico.
      { key: :analytics, events: %w[analytics_traffic_drop analytics_traffic_spike] },
      # SEO (CYRA-528): un rilievo grave nuovo sul sito. Gruppo proprio e non dentro le statistiche:
      # chi tiene d'occhio le visite non è per forza chi rimette a posto le pagine.
      { key: :seo, events: %w[seo_issue_new] },
      # Idee (CYRA-147): nuova idea e nuovo commento a un'idea.
      { key: :ideas, events: %w[idea_created idea_commented] },
      # Attività da fare / carico di lavoro (CYRA-147): scadenza imminente o superata.
      { key: :workload, events: %w[workload_due_soon] },
      # Dataset (CYRA-147): addestramento finito o fallito.
      { key: :datasets, events: %w[dataset_training_completed dataset_training_failed] },
      # Servizi interni (CYEM-2): componenti da cui dipendono funzioni che degradano in silenzio.
      # CYRA-712 aggiunge le due metà dell'AI nello stesso gruppo: chi segue la ricerca per
      # significato segue anche l'assistente — sono lo stesso pezzo di prodotto per chi lo usa.
      { key: :services, events: %w[embedding_down ai_unavailable ai_available cache_unavailable] }
    ].freeze

    EVENT_TYPES = GROUPS.flat_map { |group| group[:events] }.freeze

    # CYRA-488 — la NATURA è la classificazione macro (poche categorie) che aggrega i gruppi di dominio:
    # separa a colpo d'occhio gli avvisi tecnici ripetuti (systems) dai messaggi su cui un umano deve
    # agire (tickets) e dagli allarmi sugli agenti di automazione (agents). È DERIVATA dall'event_type
    # via i gruppi, non persistita (risolve l'«Aperto» del ticket): come critical?, la natura è una
    # proprietà del tipo, non un dato da salvare per riga. Ordine = ordine delle schede nel notification
    # center (il dominio umano per primo, come i GROUPS). Ogni gruppo appartiene a ESATTAMENTE una
    # natura e le nature coprono tutti gli event_type (garantito da spec, gemello della completezza).
    NATURES = [
      { key: :tickets, groups: %i[tickets chat ideas workload] },
      { key: :systems, groups: %i[errors logs performance uptime crons servers secrets tokens
                                   vulnerabilities analytics seo datasets services] },
      { key: :agents, groups: %i[agents] }
    ].freeze

    NATURE_EVENT_TYPES = NATURES.to_h { |nature|
      [ nature[:key], GROUPS.select { |group| nature[:groups].include?(group[:key]) }
                            .flat_map { |group| group[:events] }.freeze ]
    }.freeze

    # Eventi CRITICI: guasti gravi di infrastruttura di produzione (sito giù, server giù, database
    # irraggiungibile, cron mancato). Scavalcano SEMPRE le quiet hours nella consegna email (CYRA-479):
    # di notte l'email è l'unico canale che sveglia qualcuno, trattenerla equivale a spegnere il
    # monitoraggio proprio quando serve. Vocabolario UNICO — la criticità è una proprietà dell'evento,
    # non una lista parallela nel delivery layer né una terza tassonomia (rischio dichiarato nel ticket).
    # Sottoinsieme di EVENT_TYPES (garantito da spec): mai un event_type fuori dal catalogo.
    CRITICAL_EVENT_TYPES = %w[uptime_down server_down server_db_down server_replication_down cron_missed cluster_down].freeze

    # CYRA-315 — le CONVERSAZIONI: le notifiche a cui una persona risponde (menzioni, commenti, esiti
    # di review sui ticket, menzioni in chat). Sottoinsieme della natura :tickets, che è più larga
    # (comprende anche assegnazioni, cambi di stato, idee e scadenze: notizie, non botta e risposta).
    # Vive qui e non in Home::ActionInbox — dove nacque — perché era un vocabolario di UNA sola
    # pagina: la Home contava 185 conversazioni e mandava a un elenco che ne dichiarava 754, perché
    # la destinazione quel taglio non sapeva nemmeno esprimerlo. Come CRITICAL_EVENT_TYPES è una
    # proprietà del TIPO, non un dato per riga, e resta sottoinsieme di EVENT_TYPES (garantito da spec).
    CONVERSATION_EVENT_TYPES = %w[
      ticket_commented ticket_mentioned ticket_review_requested ticket_review_rejected chat_mentioned
    ].freeze

    def self.groups = GROUPS.map { |group| Group.new(group[:key], group[:events]) }
    # The internal services group concerns CloseYourIt itself: only the gods see it (CYRA-875).
    def self.groups_for(account) = account&.god? ? groups : groups.reject { |group| group.key == :services }
    def self.event_types = EVENT_TYPES
    def self.include?(event_type) = EVENT_TYPES.include?(event_type.to_s)
    def self.entry(event_type) = include?(event_type) ? Entry.new(event_type.to_s) : nil

    # CYRA-488 — le nature nell'ordine di resa, ciascuna con i suoi event_type.
    def self.natures = NATURES.map { |nature| Nature.new(nature[:key], NATURE_EVENT_TYPES.fetch(nature[:key])) }

    # Event_type appartenenti alla natura (per il filtro server-side). Natura ignota/nil → [] (vale
    # come nessun filtro, stessa regola dei vocabolari chiusi degli altri elenchi).
    def self.nature_event_types(key)
      return [] if key.blank?

      NATURE_EVENT_TYPES.fetch(key.to_s.to_sym, [])
    end

    # Natura di un event_type, o nil se fuori catalogo.
    def self.nature_for(event_type)
      NATURE_EVENT_TYPES.find { |_key, events| events.include?(event_type.to_s) }&.first
    end

    # Chiave del gruppo di dominio dell'evento, o nil se fuori catalogo (argomenti Telegram, CYRA-852).
    def self.group_for(event_type)
      GROUPS.find { |group| group[:events].include?(event_type.to_s) }&.fetch(:key)
    end

    # Questo evento è un guasto grave che scavalca le quiet hours? (CYRA-479)
    def self.critical?(event_type) = CRITICAL_EVENT_TYPES.include?(event_type.to_s)

    # Gli event_type conversazionali (CYRA-315): li usano la colonna delle conversazioni in Home e il
    # filtro del centro notifiche a cui quella colonna manda — un vocabolario solo, due letture.
    def self.conversation_event_types = CONVERSATION_EVENT_TYPES

    # Un gruppo di dominio con la sua etichetta i18n e le voci ordinate.
    Group = Struct.new(:key, :event_types) do
      def label = I18n.t("member.notifications.groups.#{key}")
      def entries = event_types.map { |event_type| Entry.new(event_type) }
    end

    # Una natura (categoria macro) con la sua etichetta i18n e gli event_type che la compongono
    # (CYRA-488). Usata dalle schede del notification center per filtrare e contare le non lette.
    Nature = Struct.new(:key, :event_types) do
      def label = I18n.t("member.notifications.natures.#{key}")
    end

    # Una singola notifica: titolo/descrizione via i18n, tono/icona dalla mappa condivisa con il
    # notification center (AlertingHelper::EVENT_TONES).
    Entry = Struct.new(:event_type) do
      def title = I18n.t("member.notifications.catalog.#{event_type}.title")
      def description = I18n.t("member.notifications.catalog.#{event_type}.description")
      def tone = AlertingHelper::EVENT_TONES.fetch(event_type, AlertingHelper::DEFAULT_TONE)
      def icon = tone[:icon]
    end
  end
end
