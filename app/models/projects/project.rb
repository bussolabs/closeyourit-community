module Projects
  class Project < ApplicationRecord
    attr_readonly :sentry_project_id
    belongs_to :cto, class_name: "Accounts::Account", optional: true

    def effective_cto = cto || organization.cto
    include Iconable

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :projects
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true
    belongs_to :group,
               class_name: "Projects::Group",
               optional: true,
               inverse_of: :projects
    # Assegnatario di default dei ticket del progetto (1° livello del fallback progetto → team → org,
    # applicato in Ticketing::CreateTicket). Opzionale; dev'essere membro dell'org (validato sotto).
    belongs_to :default_assignee,
               class_name: "Accounts::Account",
               optional: true,
               inverse_of: false

    has_many :tickets,
             class_name: "Ticketing::Ticket",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # Idee del progetto (proposte votabili/commentabili, promuovibili a ticket).
    has_many :ideas,
             class_name: "Ideas::Idea",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # Help desk requests written by the visitors of the project's sites (CYRA-940).
    has_many :helpdesk_requests,
             class_name: "Helpdesk::Request",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # Activity-log generalizzato (polimorfico): cronologia create/update del progetto.
    has_many :activity_events,
             class_name: "Activity::Event",
             as: :subject,
             dependent: :destroy

    has_many :tokens,
             class_name: "Projects::Token",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    has_many :source_secret_provisions,
             class_name: "Secrets::Provision",
             foreign_key: :source_project_id,
             inverse_of: :source_project,
             dependent: :destroy
    has_many :destination_secret_provisions,
             class_name: "Secrets::Provision",
             foreign_key: :destination_project_id,
             inverse_of: :destination_project,
             dependent: :destroy

    # Variabili d'ambiente cifrate del vault (secret per-progetto/ambiente). Vedi Secrets::Variable.
    has_many :secret_variables,
             class_name: "Secrets::Variable",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    # Override personali del valore di un secret, assegnati dall'admin (CYRA-79). Vedi Secrets::Override.
    has_many :secret_overrides,
             class_name: "Secrets::Override",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :shared_secret_delegations,
             class_name: "Secrets::Shared::Delegation",
             foreign_key: :project_id,
             dependent: :destroy
    has_many :secret_assets,
             class_name: "Secrets::Asset",
             foreign_key: :project_id,
             dependent: :destroy
    has_many :secret_asset_delegations,
             class_name: "Secrets::AssetDelegation",
             foreign_key: :project_id,
             dependent: :destroy
    has_many :delegated_secret_assets, through: :secret_asset_delegations, source: :asset

    # Audit del vault (chi legge/modifica/sincronizza i secret). Vedi Secrets::Event.
    has_many :secret_events,
             class_name: "Secrets::Event",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :delete_all
    # Richieste di modifica in attesa di approvazione a due (CYRA-138, Fase 4). Vedi Secrets::ChangeRequest.
    has_many :secret_change_requests,
             class_name: "Secrets::ChangeRequest",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :milestones,
             class_name: "Projects::Milestone",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # Documenti allegati al progetto (spec, contratti, export). Purge dei blob in cascata.
    has_many :documents,
             class_name: "Projects::Document",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # Knowledge base: le pagine sono N:N (una pagina documenta più progetti / interi gruppi).
    has_many :page_projects,
             class_name: "Connections::PageProject",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :knowledge_pages, through: :page_projects, source: :page

    has_many :book_projects,
             class_name: "Connections::BookProject",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :knowledge_books, through: :book_projects, source: :book

    # Guidance (CYRA-74) dichiarata a livello PROGETTO come owner. La legge Guidance::Resolve, non da qui.
    has_many :guidance_references,
             class_name: "Guidance::Reference",
             as: :owner,
             dependent: :destroy
    has_many :guidance_procedures,
             class_name: "Guidance::Procedure",
             as: :owner,
             dependent: :destroy

    # Dataset AI del progetto (colonne dinamiche + foto + result → prompt ottimizzato). Vedi Datasets::.
    has_many :datasets,
             class_name: "Datasets::Dataset",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # Release del progetto (tag/sha da CI o dedotte dall'ingest errori).
    has_many :releases,
             class_name: "Projects::Release",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # CYSK-26 — l'ultima fotografia di copertura per branch, pubblicata dalla CI.
    has_many :coverage_reports,
             class_name: "Projects::CoverageReport",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # Repo GitHub agganciato (1:1): presente solo se il progetto è connesso a un repo.
    has_one :github_repository,
            class_name: "Github::Repository",
            foreign_key: :project_id,
            inverse_of: :project,
            dependent: :destroy

    # Fonti di telemetria OSSERVATE (SDK/agent che hanno inviato dati) — popolate dall'ingest.
    has_many :sources,
             class_name: "Projects::Source",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :delete_all

    has_many :crash_reports, class_name: "Crashes::Report", foreign_key: :project_id, dependent: :delete_all, inverse_of: :project
    has_many :health_sessions, class_name: "SessionHealth::Session", foreign_key: :project_id, dependent: :delete_all, inverse_of: :project
    has_many :health_aggregates, class_name: "SessionHealth::Aggregate", foreign_key: :project_id, dependent: :delete_all, inverse_of: :project
    has_many :measurement_series, class_name: "Measurements::Series", foreign_key: :project_id, dependent: :delete_all
    has_many :measurement_points, class_name: "Measurements::Point", foreign_key: :project_id, dependent: :delete_all
    has_many :traces, class_name: "Traces::Trace", foreign_key: :project_id, dependent: :delete_all
    has_many :trace_spans, class_name: "Traces::Span", foreign_key: :project_id, dependent: :delete_all

    has_many :error_groups,
             class_name: "Errors::Group",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :error_events,
             class_name: "Errors::Event",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    # CYRA-153: regole di raggruppamento personalizzate applicate all'ingest.
    has_many :error_grouping_rules,
             class_name: "Errors::GroupingRule",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    has_many :replay_sessions,
             class_name: "Replays::Session",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    has_many :metric_groups,
             class_name: "Metrics::Group",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :metric_samples,
             class_name: "Metrics::Sample",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    has_many :cron_monitors,
             class_name: "Crons::Monitor",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :uptime_monitors,
             class_name: "Uptime::Monitor",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    # Vulnerabilità delle dipendenze (CYRA-506): i lockfile scoperti nel repository, le occorrenze
    # trovate su OSV.dev e lo stato di supporto dei runtime dichiarati.
    has_many :vulnerability_manifests,
             class_name: "Vulnerabilities::Manifest",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :vulnerability_findings,
             class_name: "Vulnerabilities::Finding",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :vulnerability_runtime_statuses,
             class_name: "Vulnerabilities::RuntimeStatus",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    # Cockpit SEO (CYRA-528): i siti pubblici dichiarati dal progetto, uno per ambiente. La
    # capability è la stessa dell'analytics (piattaforma web): senza un sito non c'è SEO da
    # guardare.
    has_many :seo_sites,
             class_name: "Seo::Site",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    has_many :server_links,
             class_name: "Connections::EnvironmentHost",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    has_many :logs_entries,
             class_name: "Logs::Entry",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    has_many :analytics_pageviews,
             class_name: "Analytics::Pageview",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :delete_all

    has_many :analytics_goals,
             class_name: "Analytics::Goal",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    has_many :analytics_links,
             class_name: "Analytics::Link",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # Canale chat del progetto (contextable polimorfico → niente FK a DB: senza questo dependent la
    # cancellazione del progetto lascerebbe conversazione+messaggi orfani per sempre).
    has_many :chat_conversations,
             class_name: "Chat::Conversation",
             as: :contextable,
             inverse_of: :contextable,
             dependent: :destroy

    has_many :project_platforms,
             class_name: "Connections::ProjectPlatform",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :platforms, through: :project_platforms, source: :platform

    # Capability uptime: il progetto la "ha" se dichiara ≥1 piattaforma uptime-capable (web/server).
    # Senza piattaforme → false (la sezione uptime resta nascosta finché non si aggiunge una web).
    scope :uptime_capable, -> { where(id: Connections::ProjectPlatform.uptime_capable.select(:project_id)) }

    # Capability analytics (pageview): come uptime, ma su supports_analytics (piattaforma web).
    scope :analytics_capable, -> { where(id: Connections::ProjectPlatform.analytics_capable.select(:project_id)) }

    # "Raccoglie analytics" = capability web (analytics_capable) E toggle esplicito attivo (opt-in,
    # default false). Gata select dashboard + voce nav. L'ingest è gata sul solo analytics_enabled?
    # (Api::V1::PageviewsController). Toggle nella tab Settings del progetto.
    scope :analytics_collecting, -> { analytics_capable.where(analytics_enabled: true) }

    # Capability session replay (come analytics, ma su supports_session_replay = piattaforma web).
    scope :session_replay_capable, -> { where(id: Connections::ProjectPlatform.session_replay_capable.select(:project_id)) }
    # "Registra il replay" = capability web E toggle esplicito (opt-in, default false). L'ingest è gata
    # sul solo session_replay_enabled? (Api::V1::ReplaysController); questa scope gata la UI.
    scope :session_replay_collecting, -> { session_replay_capable.where(session_replay_enabled: true) }

    has_many :project_environments,
             class_name: "Connections::ProjectEnvironment",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :environments, through: :project_environments, source: :environment

    has_many :project_memberships,
             class_name: "Connections::ProjectMembership",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy
    has_many :members, through: :project_memberships, source: :account

    # Override per-progetto della restrizione ambienti sui secret (CYRA-78): vince sulla allow-list
    # org-wide della membership. Risolto da Secrets::EnvironmentAccess.
    has_many :account_secret_accesses,
             class_name: "Connections::AccountSecretAccess",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # Team collegati direttamente a questo progetto (scope RBAC).
    has_many :team_accesses,
             class_name: "Connections::TeamProjectAccess",
             foreign_key: :project_id,
             inverse_of: :project,
             dependent: :destroy

    # Preferenze per-progetto (jsonb). logs_retention_days / analytics_retention_days / ... = override
    # della retention (livello più vicino nella gerarchia god → org → progetto); blank → eredita.
    # NIENTE servers_retention_days: i dati server sono org-scoped nel data model (CYRA-159), senza
    # livello progetto — vedi Organizations::Organization e Servers::Retention.
    has_many :source_map_artifacts, class_name: "Artifacts::SourceMap", dependent: :destroy
    has_many :native_symbol_artifacts, class_name: "Artifacts::NativeSymbol", dependent: :destroy
    has_many :proguard_map_artifacts, class_name: "Artifacts::ProguardMap", dependent: :destroy

    store_accessor :preferences, :artifacts_retention_days, :crashes_retention_days, :session_health_retention_days, :measurements_retention_days, :traces_retention_days, :logs_retention_days, :analytics_retention_days, :performance_alert_threshold, :replay_retention_days,
                   :errors_retention_days, :performance_retention_days, :uptime_retention_days,
                   :performance_fast_ms, :performance_slow_ms,
                   :workspace_path, :vulnerability_auto_ticket

    # Ticket automatico per le vulnerabilità gravi (CYRA-506): acceso salvo scelta contraria. Vive
    # nelle preferenze e non in una colonna perché è un interruttore, non un dato del progetto — e
    # perché spegnerlo su un progetto con centinaia di dipendenze transitive dev'essere immediato,
    # senza un rilascio. `nil` = mai toccato = acceso.
    def vulnerability_auto_ticket? = vulnerability_auto_ticket.nil? || ActiveModel::Type::Boolean.new.cast(vulnerability_auto_ticket)

    # Normalizza la retention a Integer o nil (un form vuoto "" → nil = eredita).
    def logs_retention_days=(value)
      super(value.presence&.to_i)
    end

    def analytics_retention_days=(value)
      super(value.presence&.to_i)
    end

    def replay_retention_days=(value)
      super(value.presence&.to_i)
    end

    def errors_retention_days=(value)
      super(value.presence&.to_i)
    end

    def performance_retention_days=(value)
      super(value.presence&.to_i)
    end

    def uptime_retention_days=(value)
      super(value.presence&.to_i)
    end

    # CYRA-341 — soglie (ms) che decidono il colore di una durata: sotto `fast` è verde, fino a
    # `slow` ambra, oltre rosso. Blank → valore di sistema (Metrics::Thresholds).
    def performance_fast_ms=(value)
      super(value.presence&.to_i)
    end

    def performance_slow_ms=(value)
      super(value.presence&.to_i)
    end

    # Soglia (n. occorrenze del gruppo) oltre cui un performance_issue genera un alert; blank → default.
    def performance_alert_threshold=(value)
      super(value.presence&.to_i)
    end

    def performance_alert_threshold
      super.presence&.to_i || Metrics::Constants::ALERT_THRESHOLD_DEFAULT
    end

    # Origin allowlist del public ingest (CYRA-109): difesa browser AGGIUNTIVA, mai autenticazione.
    # Accetta un array o una stringa libera (righe/virgole/spazi), normalizza a origini pulite
    # (schema://host[:port], downcase, senza slash finale) e deduplica. Vuota = nessun vincolo.
    def allowed_origins=(value)
      list = value.is_a?(Array) ? value : value.to_s.split(/[\s,]+/)
      super(list.filter_map { |origin| normalize_origin(origin) }.uniq)
    end

    # True se il progetto ha dichiarato almeno un'origine (l'allowlist è attiva).
    def origin_allowlist? = allowed_origins.present?

    # True se l'origine è ammessa: sempre quando l'allowlist è vuota (nessun vincolo di provenienza),
    # altrimenti solo se l'origine normalizzata è elencata. La presenza dell'header Origin va decisa
    # dal chiamante PRIMA (l'allowlist non è autenticazione); qui un'origine assente con allowlist
    # attiva → false (fail-closed).
    def origin_allowed?(origin)
      return true unless origin_allowlist?

      allowed_origins.include?(normalize_origin(origin))
    end

    normalizes :name, with: ->(name) { name.strip }
    normalizes :key, with: ->(key) { key.strip.upcase }
    normalizes :description, with: ->(value) { value.strip }

    # A project inside a group that has a color wears the group's color: the group reads as one thing.
    before_validation :take_group_color, if: -> { group_id.present? && (new_record? || group_id_changed? || color_changed?) }

    validates :name, presence: true
    validates :key, presence: true,
              format: { with: /\A[A-Z0-9]+\z/ },
              length: { maximum: 4 },
              uniqueness: { scope: :organization_id }
    validates :artifacts_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true

    def artifacts_retention_days=(value)
      super(value.presence)
    end

    validates :crashes_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true

    def crashes_retention_days=(value)
      super(value.presence)
    end

    validates :session_health_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true

    def session_health_retention_days=(value)
      super(value.presence)
    end

    validates :measurements_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true

    def measurements_retention_days=(value)
      super(value.presence)
    end

    validates :traces_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true

    def traces_retention_days=(value)
      super(value.presence)
    end

    validates :logs_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true
    validates :analytics_retention_days, numericality: { only_integer: true, in: 1..730 }, allow_nil: true
    validates :replay_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true
    validates :errors_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true
    validates :performance_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true
    validates :uptime_retention_days, numericality: { only_integer: true, in: 1..730 }, allow_nil: true
    validates :performance_alert_threshold, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :performance_fast_ms, numericality: { only_integer: true, in: 1..600_000 }, allow_nil: true
    validates :performance_slow_ms, numericality: { only_integer: true, in: 1..600_000 }, allow_nil: true
    validate :duration_thresholds_ordered
    validate :group_must_match_organization
    validate :default_assignee_belongs_to_organization
    validate :cto_is_visible_human_member
    validate :allowed_origins_well_formed

    # Un'origine valida = schema http(s) + host (lettere/cifre/punto/trattino) + porta opzionale.
    # Niente path/query/frammento: un header Origin è sempre e solo schema://host[:port] (CYRA-109).
    ALLOWED_ORIGIN_FORMAT = %r{\Ahttps?://[a-z0-9.-]+(?::\d+)?\z}

    # True se almeno una piattaforma dichiarata è uptime-capable (web/server). Gata la sezione uptime.
    def supports_uptime? = platforms.uptime_capable.exists?

    # True se almeno una piattaforma dichiarata è analytics-capable (web). Gata la dashboard analytics.
    def supports_analytics? = platforms.analytics_capable.exists?

    # True se almeno una piattaforma dichiarata è session-replay-capable (web). Gata la UI del replay.
    def supports_session_replay? = platforms.session_replay_capable.exists?

    # Conteggio dei ticket per categoria (Da fare / In corso / Concluso / Non chiusi), definizione
    # unica riusata da header progetto, KPI card e lista — identica tra overview e tab (CYRA-358).
    def ticket_tally = Ticketing::Tally.for(tickets)

    private

    def take_group_color
      self.color = group.color if group&.color.present?
    end

    # Ogni origine dichiarata deve essere ben formata (schema://host[:port]); altrimenti :invalid.
    def allowed_origins_well_formed
      return if allowed_origins.blank?
      return if allowed_origins.all? { |origin| origin.match?(ALLOWED_ORIGIN_FORMAT) }

      errors.add(:allowed_origins, :invalid)
    end

    # Origine → forma canonica per storage e confronto: strip, downcase, senza slash finale; blank → nil.
    def normalize_origin(raw)
      raw.to_s.strip.downcase.chomp("/").presence
    end

    # CYRA-341 — la soglia del verde deve stare sotto quella del rosso, altrimenti la fascia di mezzo
    # non esiste e il colore torna a essere un giudizio incomprensibile. Il confronto è sui valori
    # EFFETTIVI: chi imposta una sola delle due la sta confrontando con quella di sistema.
    def duration_thresholds_ordered
      return if performance_fast_ms.blank? && performance_slow_ms.blank?

      fast = Metrics::Thresholds.resolve(performance_fast_ms) || Metrics::Group::FAST_MS
      slow = Metrics::Thresholds.resolve(performance_slow_ms) || Metrics::Group::MEDIUM_MS
      errors.add(:performance_fast_ms, :greater_than_or_equal_to_slow) if fast >= slow
    end

    # Integrità tenant: il gruppo deve appartenere alla stessa org del progetto.
    def group_must_match_organization
      return if group.blank?

      errors.add(:group, :invalid) if group.organization_id != organization_id
    end

    # Integrità tenant (anti-BOLA): il default_assignee (opzionale) dev'essere membro dell'org del
    # progetto, come l'assignee del ticket (Ticketing::Ticket#reporter_and_assignee_belong_to_organization).
    def default_assignee_belongs_to_organization
      return if default_assignee.blank?

      errors.add(:default_assignee, :not_member) unless default_assignee.member_of_organization?(organization_id)
    end

    def cto_is_visible_human_member
      return if cto.blank?

      visible = cto.human? && cto.member_of_organization?(organization_id) &&
                Authorization::VisibleScope.new(account: cto, organization:).projects.exists?(id)
      errors.add(:cto, :invalid) unless visible
    end
  end
end
