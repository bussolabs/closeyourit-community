module Organizations
  class Organization < ApplicationRecord
    belongs_to :cto, class_name: "Accounts::Account", optional: true
    # Preferenze org (jsonb). default_projects_view = modalità lista progetti di default per i
    # membri dell'org senza preferenza personale (cards/table); nil → "cards".
    # logs_retention_days / analytics_retention_days / errors_retention_days /
    # performance_retention_days / uptime_retention_days = retention di default dell'org (livello
    # intermedio god → org → progetto); blank → eredita dal god. servers_retention_days = STESSO
    # livello ma è l'UNICO livello intermedio per i server (CYRA-159, org-scoped, niente progetto).
    store_accessor :preferences, :artifacts_retention_days, :crashes_retention_days, :session_health_retention_days, :measurements_retention_days, :traces_retention_days, :default_projects_view, :logs_retention_days, :analytics_retention_days,
                   :errors_retention_days, :performance_retention_days, :servers_retention_days, :uptime_retention_days

    # Normalizza la retention a Integer o nil (un form vuoto "" → nil = eredita).
    def logs_retention_days=(value)
      super(value.presence&.to_i)
    end

    def analytics_retention_days=(value)
      super(value.presence&.to_i)
    end

    def errors_retention_days=(value)
      super(value.presence&.to_i)
    end

    def performance_retention_days=(value)
      super(value.presence&.to_i)
    end

    def servers_retention_days=(value)
      super(value.presence&.to_i)
    end

    def uptime_retention_days=(value)
      super(value.presence&.to_i)
    end

    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true
    # Assegnatario di default dei ticket dell'org (3° e ultimo livello del fallback progetto → team →
    # org, applicato in Ticketing::CreateTicket). Opzionale; dev'essere membro dell'org (validato sotto).
    belongs_to :default_assignee,
               class_name: "Accounts::Account",
               optional: true,
               inverse_of: false

    has_many :memberships,
             class_name: "Connections::Membership",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :accounts,
             through: :memberships,
             source: :account

    has_one :owner_membership,
            -> { where(role: :owner) },
            class_name: "Connections::Membership",
            foreign_key: :organization_id
    has_one :owner, through: :owner_membership, source: :account

    has_many :projects,
             class_name: "Projects::Project",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    has_many :secret_provisions,
             class_name: "Secrets::Provision",
             foreign_key: :organization_id,
             dependent: :destroy

    has_many :shared_secret_variables,
             class_name: "Secrets::Shared::Variable",
             foreign_key: :organization_id,
             dependent: :destroy
    has_many :shared_secret_events,
             class_name: "Secrets::Shared::Event",
             foreign_key: :organization_id,
             dependent: :delete_all
    has_many :secret_assets,
             class_name: "Secrets::Asset",
             foreign_key: :organization_id,
             dependent: :destroy
    has_many :secret_asset_events,
             class_name: "Secrets::AssetEvent",
             foreign_key: :organization_id,
             dependent: :delete_all

    # Installazione GitHub App dell'org (1:1): presente solo se l'org ha connesso l'App.
    has_one :github_installation,
            class_name: "Github::Installation",
            foreign_key: :organization_id,
            inverse_of: :organization,
            dependent: :destroy
    # How the organization uses the AI; no row = the platform values (CYRA-914).
    has_one :ai_setting,
            class_name: "Organizations::AiSetting",
            foreign_key: :organization_id,
            inverse_of: :organization,
            dependent: :delete
    has_many :groups,
             class_name: "Projects::Group",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    has_many :knowledge_books,
             class_name: "Knowledge::Book",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    # Le pagine KB sono N:N su progetti/gruppi (o org-wide senza scope): l'org è la radice di tenancy.
    has_many :knowledge_pages,
             class_name: "Knowledge::Page",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # Guidance (CYRA-74) dichiarata a livello ORG come owner. La legge Guidance::Resolve, non da qui.
    has_many :guidance_references,
             class_name: "Guidance::Reference",
             as: :owner,
             dependent: :destroy
    has_many :guidance_procedures,
             class_name: "Guidance::Procedure",
             as: :owner,
             dependent: :destroy
    has_many :uptime_groups,
             class_name: "Uptime::Group",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :teams,
             class_name: "Teams::Team",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :tickets, through: :projects
    has_many :error_groups, through: :projects
    has_many :uptime_monitors, through: :projects
    has_many :metric_groups, through: :projects
    has_many :cron_monitors, through: :projects

    has_many :ticket_statuses,
             class_name: "Types::TicketStatus",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :ticket_priorities,
             class_name: "Types::TicketPriority",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :platforms,
             class_name: "Types::Platform",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    has_many :environments,
             class_name: "Types::Environment",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # Matrice funzionalità × piattaforme (CYRA-256): lo stato della cella è un lookup org-scoped,
    # la struttura (categorie → funzionalità) è per macro-progetto ma resta tenant-scoped.
    has_many :feature_statuses,
             class_name: "Types::FeatureStatus",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :feature_categories,
             class_name: "Product::Category",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :features,
             class_name: "Product::Feature",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    has_many :invitations,
             class_name: "Connections::Invitation",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # RBAC: ruoli dinamici dell'org + assegnazioni/override per-account + audit dei cambi-permesso.
    has_many :roles,
             class_name: "Authorization::Role",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :account_roles,
             class_name: "Authorization::AccountRole",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :account_permissions,
             class_name: "Authorization::AccountPermission",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :authorization_events,
             class_name: "Authorization::Event",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # Token CLI a livello utente emessi per questa org (vedi Accounts::ApiToken).
    has_many :api_tokens,
             class_name: "Accounts::ApiToken",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # Alerting (Fase 1): regole, notifiche recapitate, preferenze personali per-org.
    has_many :alerting_rules,
             class_name: "Alerting::Rule",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :alerting_notifications,
             class_name: "Alerting::Notification",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :alerting_preferences,
             class_name: "Alerting::Preference",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # Canali di consegna esterni degli alert (webhook/telegram), org-scoped.
    has_many :alerting_channels,
             class_name: "Alerting::Channel",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # Le credenziali con cui QUESTA organizzazione usa i servizi esterni (CYRA-544): la sua chiave
    # PageSpeed. Non sono segreti del vault — quelli appartengono alle
    # applicazioni del cliente e si sincronizzano su GitHub; queste le usa CloseYourIt per lei.
    has_many :integration_credentials,
             class_name: "Integrations::Credential",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # Server monitoring: host fisici della flotta + token universali degli agent (org-scoped,
    # NON per-progetto — vedi Servers::Host).
    has_many :server_hosts,
             class_name: "Servers::Host",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :server_enrollment_tokens,
             class_name: "Servers::EnrollmentToken",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    # Kubernetes clusters watched by closeyourit-kube (CYAG-22).
    has_many :clusters,
             class_name: "Clusters::Cluster",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # Token org di bootstrap con cui closeyourit-automator registra le installazioni. Il catalogo dei typed
    # agent è stato rimosso (MT-9): nel modello host-first l'unità operativa è l'Agent Host.
    has_many :agent_tokens,
             class_name: "Agents::Token",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :agent_hosts,
             class_name: "Agents::Host",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    # Bundle skill versionato pinnato per l'org (singleton): la versione del plugin che gli host clonano (B.2).
    has_one :skill_bundle,
            class_name: "Agents::SkillBundle",
            foreign_key: :organization_id,
            inverse_of: :organization,
            dependent: :destroy
    has_one :skill_release_pin, class_name: "Agents::SkillReleasePin", inverse_of: :organization, dependent: :destroy
    # The Claude credential lent to the automator machines (CYAU-224); a machine's own one is not it (CYRA-1052).
    has_one :claude_credential, -> { where(host_id: nil) },
            class_name: "Agents::ClaudeCredential",
            foreign_key: :organization_id,
            inverse_of: :organization,
            dependent: :destroy
    # The OpenRouter key OpenCode reviews with on the automator machines (CYAU-228).
    has_one :openrouter_credential,
            class_name: "Agents::OpenrouterCredential",
            foreign_key: :organization_id,
            inverse_of: :organization,
            dependent: :destroy
    # Who works and who reviews for every machine without a choice of its own (CYAU-227).
    has_one :automator_setting,
            class_name: "Agents::AutomatorSetting",
            foreign_key: :organization_id,
            inverse_of: :organization,
            dependent: :destroy
    # Le FK cancellano lease e tombstone senza invertire l'ordine dei lock applicativi.
    has_many :agent_leases,
             class_name: "Agents::Lease",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: nil
    has_many :agent_lease_tombstones,
             class_name: "Agents::Leases::Tombstone",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: nil
    has_many :agent_limit_reservations,
             class_name: "Agents::LimitReservation",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :agent_ticket_queue_deferrals,
             class_name: "Agents::TicketQueueDeferral",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: nil

    # Liste di todo personali dei membri, scoped a quest'org (FK on_delete: :cascade ⇄ dependent: :destroy).
    has_many :todo_lists,
             class_name: "Todos::List",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # CYRA-654 — i rimandi della home dei membri, scoped a quest'org (FK on_delete: :cascade).
    has_many :home_deferrals,
             class_name: "Home::Deferral",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    # Vault personale dei membri, scoped a quest'org (FK on_delete: :cascade). Le variabili cadono con l'org
    # (:destroy); l'audit personale è alto-volume append-only → :delete_all (come shared_secret_events).
    has_many :personal_secret_variables,
             class_name: "Secrets::Personal::Variable",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :personal_secret_events,
             class_name: "Secrets::Personal::Event",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :delete_all
    # File segreti personali dei membri, scoped a quest'org (CYRA-133, FK on_delete: :cascade).
    has_many :personal_secret_assets,
             class_name: "Secrets::Personal::Asset",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy
    has_many :personal_secret_asset_events,
             class_name: "Secrets::Personal::AssetEvent",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :delete_all

    # Richieste AI asincrone dei membri, scoped a quest'org (draft effimeri).
    has_many :ai_requests,
             class_name: "Ai::Request",
             foreign_key: :organization_id,
             inverse_of: :organization,
             dependent: :destroy

    normalizes :name, with: ->(name) { name.strip }
    normalizes :slug, with: ->(slug) { slug.strip.downcase }

    validates :name, presence: true
    validates :slug, presence: true, uniqueness: true,
              format: { with: /\A[a-z0-9-]+\z/ }
    validates :default_projects_view, inclusion: { in: Projects::Constants::VIEWS }, allow_nil: true
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
    validates :errors_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true
    validates :performance_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true
    validates :servers_retention_days, numericality: { only_integer: true, in: 1..365 }, allow_nil: true
    validates :uptime_retention_days, numericality: { only_integer: true, in: 1..730 }, allow_nil: true
    validate :default_assignee_belongs_to_organization
    validate :cto_is_human_member

    scope :active, -> { where(suspended_at: nil) }
    scope :suspended, -> { where.not(suspended_at: nil) }

    def suspended?
      suspended_at.present?
    end

    # Slug univoco dal nome (riusato dal provisioning god e dal seed).
    def self.generate_unique_slug(name)
      base = name.to_s.parameterize.presence || "org"
      slug = base
      counter = 2
      while exists?(slug: slug)
        slug = "#{base}-#{counter}"
        counter += 1
      end
      slug
    end

    private

    # Integrità tenant (anti-BOLA): il default_assignee (opzionale) dev'essere membro di quest'org.
    def default_assignee_belongs_to_organization
      return if default_assignee.blank?

      errors.add(:default_assignee, :not_member) unless default_assignee.member_of_organization?(id)
    end

    def cto_is_human_member
      return if cto.blank?

      errors.add(:cto, :invalid) unless cto.human? && cto.member_of_organization?(id)
    end
  end
end
