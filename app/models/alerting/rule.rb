# frozen_string_literal: true

module Alerting
  # Regola che decide QUANDO avvisare: tipo evento (nuovo errore / regressione / uptime down / up /
  # soglia metrica), scope (progetto + environment; nil = tutti), throttle anti-spam, on/off.
  # Le regole sono configurazione org-level (gated da alerts.manage).
  class Rule < ApplicationRecord
    self.table_name = "alerting_rules"

    # Measurement rules require project visibility; legacy rules retain organization visibility.
    scope :with_visible_measurements, ->(projects) {
      where.not(event_type: :measurement_threshold).or(where(project_id: projects.select(:id)))
    }

    # Livelli errore allineati a Errors::Group (min_level è un intero confrontabile col level dell'evento).
    LEVELS = Errors::Group.levels.freeze

    # Coercizione nome→intero + validazione di min_level, condivisa con Alerting::Preference (CYRA-236).
    include MinLevelCoercible

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :created_by, class_name: "Accounts::Account", optional: true
    belongs_to :project, class_name: "Projects::Project", optional: true
    belongs_to :environment, class_name: "Types::Environment", optional: true
    belongs_to :measurement_series, class_name: "::Measurements::Series", optional: true

    has_many :notifications, class_name: "Alerting::Notification", foreign_key: :rule_id,
             inverse_of: :rule, dependent: :nullify
    # CYRA-519 — le macchine su cui QUESTA regola tace. La regola resta accesa per tutte le altre:
    # un falso positivo su due runner non deve costare il segnale sull'intera flotta.
    has_many :host_exclusions, class_name: "Alerting::RuleHostExclusion", foreign_key: :rule_id,
             inverse_of: :rule, dependent: :destroy
    has_many :excluded_hosts, through: :host_exclusions, source: :host

    has_many :rule_channels, class_name: "Alerting::RuleChannel", foreign_key: :rule_id,
             inverse_of: :rule, dependent: :destroy
    has_many :channels, through: :rule_channels

    enum :event_type, {
      error_new: 0, error_regression: 1, uptime_down: 2, uptime_up: 3, metric_threshold: 4,
      uptime_ssl_expiring: 5, cron_missed: 6,
      # Server monitoring (org-scoped, subject = Servers::Host): valori SOLO in append (il 6 è di cron_missed).
      server_down: 7, server_up: 8, server_cpu: 9, server_mem: 10, server_disk: 11,
      server_temp: 12, server_service_failed: 13, server_smart_failing: 14,
      # Spike/surge di un errore GIÀ unresolved (subject = Errors::Group, come error_new/regression):
      # esplode di volume senza essere nuovo né una regressione. Valore APPESO (il 14 è
      # server_smart_failing).
      error_spike: 15,
      # Log error/fatal (subject = Logs::Entry): lo stream strutturato genera un alert come gli errori
      # sui soli livelli allarmanti (subtype-aware, filtro a monte in Logs::Ingest::Record). Usa
      # min_level come le regole errore. Valore APPESO (il 15 è error_spike).
      log_alert: 16,
      # Database sull'host (subject = Servers::Host come gli altri server_*): non raggiungibile,
      # connessioni oltre soglia, lag di replica oltre soglia. Valori APPESI (il 16 è log_alert).
      server_db_down: 17, server_db_connections: 18, server_replication_lag: 19,
      # Agenti di automazione bloccati (CYRA-212, org-scoped, subject = Organizations::Organization):
      # host attivi che non concludono più nulla. Valore APPESO (il 19 è server_replication_lag).
      agents_stalled: 20,
      # Container spariti fra due push (CYRA-248, org-scoped, subject = Servers::Host come gli altri
      # server_*): un container morto non compare più nella lista Docker. Transizione, senza soglia.
      # Valore APPESO (il 20 è agents_stalled).
      server_container_down: 21,
      # Una macchina di automazione butta via il lavoro (CYRA-282, org-scoped, subject = Agents::Host): una
      # quota anomala di lavorazioni fallite su UN host. Distinto da agents_stalled (org, zero progressi):
      # quello tace se un altro host lavora, questo guarda il singolo host. Senza soglia (la quota la applica
      # il detector). Valore APPESO (il 21 è server_container_down).
      agents_host_failing: 22,
      # Il monitor risponde ma è lento oltre la soglia configurata (CYRA-151, subject = Uptime::Monitor come
      # uptime_ssl_expiring): project-scoped come gli altri uptime. La soglia è per-monitor, non sulla regola.
      # Valore APPESO (il 22 è agents_host_failing).
      uptime_slow: 23,
      # Traffico del sito (CYRA-147, subject = Projects::Project): crollo o picco anomalo delle visite,
      # rilevato da un detector periodico. Senza soglia (l'anomalia la calcola il detector). Valori APPESI
      # (il 23 è uptime_slow).
      analytics_traffic_drop: 24,
      analytics_traffic_spike: 25,
      # Idee (CYRA-147, subject = Ideas::Idea/Comment): nuova idea o nuovo commento in un progetto.
      # Project-scoped come gli errori. Valori APPESI (il 25 è analytics_traffic_spike).
      idea_created: 26,
      idea_commented: 27,
      # Attività di carico di lavoro in scadenza (CYRA-147, org-scoped, subject = Workload::Action): le
      # action sono team-scoped (nessun progetto), i destinatari sono i partecipanti. Valore APPESO
      # (il 27 è idea_commented).
      workload_due_soon: 28,
      # Addestramento dataset finito o fallito (CYRA-147, subject = Datasets::Training): project-scoped
      # via il dataset. Valori APPESI (il 28 è workload_due_soon).
      dataset_training_completed: 29,
      dataset_training_failed: 30,
      # Una macchina di automazione è ferma (CYRA-450, org-scoped, subject = Agents::Host): non batte da oltre
      # la soglia di allarme mentre l'arretrato invecchia. Distinto da agents_host_failing (macchina che gira
      # ma butta via il lavoro): questa non risponde proprio. Senza soglia (la applica il detector). Valore
      # APPESO (il 30 è dataset_training_failed).
      agents_host_stale: 31,
      # Vulnerabilità di una dipendenza (CYRA-506, subject = Vulnerabilities::Finding): project-scoped
      # come gli errori. La gravità si filtra con min_level, che per questo evento legge la scala GHSA
      # (unknown/low/moderate/high/critical) invece dei livelli di log. Valore APPESO (il 31 è
      # agents_host_stale).
      vulnerability_new: 32,
      # Runtime fuori supporto (CYRA-506, subject = Vulnerabilities::RuntimeStatus): non è una falla ma
      # la causa a monte — una versione che non riceve più patch di sicurezza. Senza soglia: lo stato
      # lo calcola il controllo. Valore APPESO (il 32 è vulnerability_new).
      runtime_eol: 33,
      # Servizio di embedding irraggiungibile (CYEM-2, org-scoped, subject = Organizations::Organization):
      # ricerca semantica, collegamenti e deduplica degradano in silenzio per scelta di progetto, quindi
      # senza questo allarme il guasto resta invisibile. Valore APPESO (il 33 è runtime_eol): la PR era
      # nata con 21, gia' preso da server_container_down mentre CYEM-2 aspettava in coda.
      embedding_down: 34,
      # Container tornati su dopo un server_container_down (CYRA-512, org-scoped, subject =
      # Servers::Host): gemello di server_up, che a server_container_down mancava — l'avviso di caduta
      # restava nel feed senza che nessuno dicesse mai che era rientrato. Valore APPESO (il 34 è
      # embedding_down).
      server_container_up: 35,
      # Capacità e transizioni infrastrutturali (CYRA-515). Tutti org-scoped, subject =
      # Servers::Host. Valori append-only (il 35 è server_container_up).
      server_db_connection_usage: 36,
      server_data_volume_disk: 37,
      server_inode: 38,
      server_replication_down: 39,
      server_replication_up: 40,
      server_container_restart_loop: 41,
      server_container_stable: 42,
      # Rilievo SEO nuovo (CYRA-528, subject = Seo::Issue): project-scoped come gli errori. La
      # gravità si filtra con min_level, che per questo evento legge la scala del dominio
      # (low/medium/high/critical). Valore APPESO (il 42 è server_container_stable): i valori di
      # questo enum non si riordinano mai, o le regole già salvate cambierebbero significato.
      seo_issue_new: 43,
      # Accesso a un segreto (CYRA-77, subject = Secrets::Event): qualcuno ha letto un valore, o ha
      # provato a leggere un ambiente che non gli spetta. Project-scoped come gli errori, e con
      # l'ambiente che conta più del progetto — «avvisami sulle letture di PRODUCTION» è il motivo
      # per cui esistono. Valori APPESI (il 43 è seo_issue_new).
      secret_read: 44,
      secret_denied: 45,
      # CYRA-676 (org-scoped, subject = Servers::Host). Due segnali già raccolti che non avvisavano
      # nessuno: aggiornamenti di sicurezza pendenti (transizione nessuno→qualcuno, il conteggio era
      # già in UI e azionabile) e host che risponde ma i cui dati sono fermi da oltre
      # SERVERS_SILENT_ALERT_AFTER_SECONDS (il caso «invia a singhiozzo: sembra sana e non lo è»
      # descritto in Servers::Host#silent?). Valori APPESI (il 45 è secret_denied).
      server_security_updates: 46,
      server_silent: 47,
      # CYRA-679 (org-scoped, subject = Servers::Host): al ritmo di riempimento attuale il volume
      # dati satura entro N giorni. Predittivo, non a soglia: il valore trasportato è la stima in
      # giorni, non una percentuale. Valore APPESO (il 47 è server_silent).
      server_disk_forecast: 48,
      # CYRA-712 (org-scoped, subject = Organizations::Organization): il servizio generativo non
      # risponde più alla chiave di quell'organizzazione, e il rientro quando torna. Gemello di
      # embedding_down per l'altra metà dell'AI — assistente, smistamento automatico e doppioni —
      # che degradava in silenzio esattamente allo stesso modo. Valori APPESI (il 48 è
      # server_disk_forecast).
      ai_unavailable: 49,
      ai_available: 50,
      # CYRA-775 (org-scoped, subject = Organizations::Organization): il nostro backend ha risposto
      # «troppe richieste» alle sonde di quell'organizzazione, quindi i loro dati non sono arrivati.
      # Esiste per NON far passare quel silenzio per un guasto delle macchine (server_down /
      # server_silent), che è quel che succedeva: sette cadute finte in venticinque minuti sulla
      # stessa macchina, e quarantanove «Dati fermi» su ventidue host in otto minuti. Valore APPESO
      # (il 50 è ai_available).
      server_ingest_rejected: 51,
      # CYRA-846 (org-scoped, subject = Organizations::Organization): la memoria temporanea
      # condivisa non risponde. I freni anti-doppione degli avvisi la usano come lucchetto e sono
      # fail-closed: cache muta = «già avvisato» → i canali esterni tacciono nel momento peggiore.
      # Valore APPESO (il 51 è server_ingest_rejected).
      cache_unavailable: 52,
      # CYAG-22 (org-scoped, subject = Clusters::Cluster/Node/Workload): Kubernetes clusters watched by
      # closeyourit-kube. Values APPENDED (52 is cache_unavailable).
      cluster_down: 53,
      cluster_up: 54,
      cluster_node_not_ready: 55,
      cluster_node_pressure: 56,
      cluster_workload_crashloop: 57,
      cluster_workload_degraded: 58,
      measurement_threshold: 59
    }, prefix: :event

    # Eventi server con soglia numerica (threshold: percent per cpu/mem/disk, °C per temp,
    # connessioni assolute per server_db_connections, secondi per server_replication_lag).
    THRESHOLD_EVENT_TYPES = %w[
      server_cpu server_mem server_disk server_temp server_db_connections server_db_connection_usage
      server_replication_lag server_data_volume_disk server_inode
    ].freeze

    normalizes :name, with: ->(value) { value.to_s.strip }

    validates :name, presence: true
    validate :validate_measurement_configuration, if: :event_measurement_threshold?
    validates :throttle_seconds, numericality: { only_integer: true, greater_than: 0 }
    validates :threshold, presence: true, numericality: { greater_than: 0 }, if: :server_threshold_event?

    # Quota degli scatti di una pagina oltre la quale una regola è "rumorosa": un quinto del totale
    # basta a farla emergere senza accendere mezza tabella (CYRA-478).
    NOISY_SHARE = 0.2

    scope :enabled, -> { where(enabled: true) }
    # CYRA-478 — silenziata a tempo: resta ATTIVA (valuta, conta, compare negli elenchi) ma non
    # notifica fino a `muted_until`. È il gate del dispatch, distinto da `enabled`: chi vuole silenzio
    # per un'ora non deve spegnere una regola per sempre e dimenticarsene.
    scope :notifying, -> { enabled.where("muted_until IS NULL OR muted_until <= ?", Time.current) }
    scope :muted, -> { where("muted_until > ?", Time.current) }

    # Silenziata ADESSO? (il confronto vive qui, non sparso nelle view)
    def muted? = muted_until.present? && muted_until > Time.current
    scope :ordered, -> { order(:name) }

    # Riguarda gli errori? Solo questi tipi usano min_level.
    # CYRA-481 — quali campi valgono per quale evento. Il form mostrava tutto per tutti e si scusava
    # nelle note («Solo regole metric_threshold», «server_cpu/mem/disk/temp»): identificatori del
    # codice in un'interfaccia italiana, che per giunta chiedono a chi compila di sapere di che tipo è
    # la propria regola. La matrice sta QUI, accanto ai predicati che la definiscono, non in una
    # configurazione a parte: se un evento nuovo cambia i campi applicabili, cambia in un posto solo e
    # il form lo segue.
    FIELD_EVENTS = {
      "measurement_series_id" => %w[measurement_threshold],
      "measurement_config" => %w[measurement_threshold],
      "min_level" => %w[error_new error_regression error_spike log_alert],
      "unhandled_only" => %w[error_new error_regression error_spike],
      "threshold_ms" => %w[metric_threshold],
      "threshold" => %w[
        server_cpu server_mem server_disk server_temp server_db_connections server_db_connection_usage
        server_replication_lag server_data_volume_disk server_inode
      ],
      # Gli eventi org-scoped (server, agenti, vault, embedding) non hanno progetto né ambiente:
      # chiederli sarebbe chiedere di scegliere fra niente.
      "project_id" => nil,
      "environment_id" => nil
    }.freeze

    # I campi che valgono per un evento: `nil` nella matrice = "tutti tranne gli org-scoped".
    def self.fields_for(event_type)
      event_type = event_type.to_s
      # CYRA-77 — gli avvisi sugli ACCESSI ai segreti (secret_read/secret_denied) sono project-scoped
      # e vivono di ambiente: restringerli a production è tutto il senso della funzione. Il prefisso
      # `secret_` non basta più a classificarli, perché nell'enum delle notifiche copre anche i
      # dispatch diretti org-level (rotazione, sync, richieste di modifica) che regole non hanno.
      # CYRA-712 — `ai_` sta qui per lo stesso motivo di `embedding_`: sono org-scoped, e
      # `matching_org_rules` ignora progetto e ambiente. Lasciarli fuori vuol dire un form che
      # chiede di restringere la regola a un progetto e un motore che quella scelta non la guarda.
      org_scoped = event_type.start_with?("server_", "agents_", "embedding_", "ai_", "cluster_")
      FIELD_EVENTS.filter_map do |field, events|
        next field if events.nil? ? !org_scoped : events.include?(event_type)
      end
    end

    # La matrice intera, per il form: { evento => [campi] }. Serve al lato client per alzare e
    # abbassare i campi al volo, senza un giro sul server a ogni cambio di tendina.
    def self.fields_matrix = event_types.keys.index_with { |event_type| fields_for(event_type) }

    def error_event? = event_error_new? || event_error_regression? || event_error_spike?

    # Riguarda i log strutturati? (subject = Logs::Entry) Usa min_level come gli errori: i livelli di
    # Logs::Entry e Errors::Group condividono gli stessi interi, quindi il confronto è diretto.
    def log_event? = event_log_alert?

    # Riguarda i server? Gli eventi server_* sono org-scoped: project/environment non si applicano.
    def server_event? = event_type.to_s.start_with?("server_")

    # Evento ORG-SCOPED puro (server_*, agents_*, workload_*): subject = host, organizzazione o action,
    # mai un progetto. Alerting::Evaluate#matching_org_rules li seleziona IGNORANDO project/environment →
    # una regola qualsiasi per quell'evento copre già tutta l'org, a prescindere dallo scope con cui è
    # stata creata. workload_* è team-scoped (CYRA-147): passa dal ramo org-scoped ma i destinatari sono
    # i partecipanti della action, non tutta l'org.
    def self.org_scoped_event?(event_type) = event_type.to_s.start_with?("server_", "agents_", "workload_", "ai_", "cluster_")

    # Richiede una soglia numerica? (server_cpu/mem/disk/temp)
    def server_threshold_event? = THRESHOLD_EVENT_TYPES.include?(event_type.to_s)

    private

    def validate_measurement_configuration
      series = measurement_series
      # A retained rule whose series was pruned remains scoped and unavailable.
      return if persisted? && series.nil? && !measurement_series_id_changed? && !measurement_config_changed? && !project_id_changed?
      unless series && series.project_id == project_id && project&.organization_id == organization_id
        errors.add(:measurement_series_id, "must belong to the selected project and organization")
        return
      end
      Measurements::Configuration.validate!(measurement_config, series: series)
      errors.add(:environment_id, "is defined by the exact measurement series") if environment_id
    rescue Measurements::Configuration::Invalid => error
      errors.add(:measurement_config, error.message)
    end
  end
end
