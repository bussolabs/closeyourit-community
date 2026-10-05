# frozen_string_literal: true

module Types
  # Piattaforma/sistema su cui gira un progetto (ios/android/web…). Lookup org-scoped, CRUD
  # gestita da admin/owner. Stesso pattern di Types::TicketStatus/TicketPriority.
  class Platform < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :platforms
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_many :project_platforms,
             class_name: "Connections::ProjectPlatform",
             foreign_key: :platform_id,
             inverse_of: :platform,
             dependent: :restrict_with_error
    has_many :projects, through: :project_platforms, source: :project
    has_many :ticket_platforms,
             class_name: "Connections::TicketPlatform",
             foreign_key: :platform_id,
             inverse_of: :platform,
             dependent: :restrict_with_error
    has_many :tickets, through: :ticket_platforms, source: :ticket
    # Celle della matrice funzionalità (CYRA-256): una piattaforma con celle compilate resta una
    # colonna della matrice anche se disattivata, quindi non si cancella finché è in uso.
    has_many :feature_platforms,
             class_name: "Connections::FeaturePlatform",
             foreign_key: :platform_id,
             inverse_of: :platform,
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
    # Piattaforme web/server (HTTP-ping possibile): abilitano la sezione uptime sui progetti che le usano.
    scope :uptime_capable, -> { where(supports_uptime: true) }
    # Piattaforme web (pagine con browser): abilitano la sezione analytics (pageview) sui progetti.
    # Colonna separata da supports_uptime: un backend API è uptime-capable ma non ha pageview.
    scope :analytics_capable, -> { where(supports_analytics: true) }

    # Solo il web (browser + rrweb) è session-replay-capable.
    scope :session_replay_capable, -> { where(supports_session_replay: true) }
  end
end
