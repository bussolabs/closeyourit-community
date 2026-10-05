# frozen_string_literal: true

module Types
  # Environment di deploy (production/staging/development…) su cui un progetto riceve errori.
  # Lookup org-scoped, CRUD admin/owner. Stesso pattern di Types::Platform: un progetto DICHIARA
  # i suoi environment (join Connections::ProjectEnvironment); un token di ingest si lega a uno di quelli.
  class Environment < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :environments
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_many :project_environments,
             class_name: "Connections::ProjectEnvironment",
             foreign_key: :environment_id,
             inverse_of: :environment,
             dependent: :restrict_with_error
    has_many :projects, through: :project_environments, source: :project
    has_many :tokens,
             class_name: "Projects::Token",
             foreign_key: :environment_id,
             inverse_of: :environment,
             dependent: :restrict_with_error
    has_many :secret_variables,
             class_name: "Secrets::Variable",
             foreign_key: :environment_id,
             inverse_of: :environment,
             dependent: :restrict_with_error
    has_many :shared_secret_values,
             class_name: "Secrets::Shared::Value",
             foreign_key: :environment_id,
             dependent: :restrict_with_error
    has_many :uptime_monitors,
             class_name: "Uptime::Monitor",
             foreign_key: :environment_id,
             inverse_of: :environment,
             dependent: :restrict_with_error
    has_many :host_links,
             class_name: "Connections::EnvironmentHost",
             foreign_key: :environment_id,
             inverse_of: :environment,
             dependent: :restrict_with_error
    has_many :seo_sites,
             class_name: "Seo::Site",
             foreign_key: :environment_id,
             inverse_of: :environment,
             dependent: :restrict_with_error

    normalizes :code, with: ->(code) { code.strip.downcase.gsub(/\s+/, "_") }
    normalizes :label, with: ->(label) { label.strip }

    validates :code, presence: true,
              format: { with: /\A[a-z][a-z0-9_]*\z/ },
              uniqueness: { scope: :organization_id }
    validates :label, presence: true
    validates :color, presence: true

    scope :active, -> { where(active: true) }
    scope :ordered, -> { order(:position, :label) }

    # servers_enabled / uptime_enabled / secrets_enabled / approval_required (boolean NOT NULL, predicati
    # AR) sono i DEFAULT di capability dell'ambiente: dicono se, di base, un progetto può attivare
    # server/uptime/secret su questo ambiente, o se le modifiche ai secret qui richiedono un secondo
    # responsabile (approval_required, CYRA-138 Fase 4 pezzo C1a — l'unico dei 4 permissivo FALSE di
    # default: l'approvazione va scelta, mai subita). Un progetto può OVERRIDE-arli per sé sulla riga
    # join Connections::ProjectEnvironment (nil lì = eredita questi default). L'enforcement vero vive nei
    # model/guard di dominio (Uptime::Monitor, Connections::EnvironmentHost, Secrets::Variable,
    # Secrets::Approval) che leggono il valore RISOLTO dalla join.
  end
end
