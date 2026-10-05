# frozen_string_literal: true

module Teams
  # Team = gruppo-di-PERSONE (org-scoped), distinto da Projects::Group (gruppo-di-progetti).
  # Riceve RUOLI (Authorization::TeamRole), non chiavi sciolte, e si collega a uno scope
  # (progetti/gruppi-di-progetti via Connections::TeamProjectAccess/TeamGroupAccess). I membri del
  # team ereditano i permessi dei ruoli del team, entro lo scope collegato. Vedi Authorization::Resolver.
  class Team < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :teams
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true
    # Assegnatario di default dei ticket dei progetti gestiti dal team (2° livello del fallback
    # progetto → team → org, applicato in Ticketing::CreateTicket). Opzionale; membro dell'org (sotto).
    belongs_to :default_assignee,
               class_name: "Accounts::Account",
               optional: true,
               inverse_of: false

    has_many :team_memberships,
             class_name: "Connections::TeamMembership",
             foreign_key: :team_id,
             inverse_of: :team,
             dependent: :destroy
    has_many :members, through: :team_memberships, source: :account

    # Scope del team (linkage = visibilità): progetti e gruppi-di-progetti collegati.
    has_many :project_accesses,
             class_name: "Connections::TeamProjectAccess",
             foreign_key: :team_id,
             inverse_of: :team,
             dependent: :destroy
    has_many :scoped_projects, through: :project_accesses, source: :project
    has_many :group_accesses,
             class_name: "Connections::TeamGroupAccess",
             foreign_key: :team_id,
             inverse_of: :team,
             dependent: :destroy
    has_many :scoped_groups, through: :group_accesses, source: :group

    # Capability del team = ruoli (live). Un team riceve RUOLI, non chiavi sciolte.
    has_many :team_roles,
             class_name: "Authorization::TeamRole",
             foreign_key: :team_id,
             inverse_of: :team,
             dependent: :destroy
    has_many :roles, through: :team_roles, source: :role

    # Canale chat del team (contextable polimorfico → niente FK a DB: senza questo dependent la
    # cancellazione del team lascerebbe conversazione+messaggi orfani per sempre).
    has_many :chat_conversations,
             class_name: "Chat::Conversation",
             as: :contextable,
             inverse_of: :contextable,
             dependent: :destroy

    # Board del carico di lavoro non-dev del team (fiere, meeting, materiale…). Vedi Workload::Action.
    has_many :workload_actions,
             class_name: "Workload::Action",
             foreign_key: :team_id,
             inverse_of: :team,
             dependent: :destroy

    normalizes :name, with: ->(name) { name.strip }

    validates :name, presence: true, uniqueness: { scope: :organization_id }
    validate :default_assignee_belongs_to_organization

    scope :ordered, -> { order(:name) }

    private

    # Integrità tenant (anti-BOLA): il default_assignee (opzionale) dev'essere membro dell'org del team.
    def default_assignee_belongs_to_organization
      return if default_assignee.blank?

      errors.add(:default_assignee, :not_member) unless default_assignee.member_of_organization?(organization_id)
    end
  end
end
