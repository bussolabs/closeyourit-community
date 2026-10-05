# frozen_string_literal: true

module Authorization
  # Ruolo dinamico (CRUD dell'owner): bundle nominato di chiavi-permesso (Authorization::Catalog).
  # Assegnabile a team (Authorization::TeamRole) e a utenti diretti (Authorization::AccountRole).
  # È un collegamento VIVO: modificare le chiavi (RolePermission) propaga subito a tutti i portatori.
  # `owner` NON è un Role: è l'enum di sistema (Connections::Membership). I Role stanno sotto owner.
  class Role < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :roles
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_many :role_permissions,
             class_name: "Authorization::RolePermission",
             foreign_key: :role_id,
             inverse_of: :role,
             dependent: :destroy
    has_many :team_roles,
             class_name: "Authorization::TeamRole",
             foreign_key: :role_id,
             inverse_of: :role,
             dependent: :destroy
    has_many :account_roles,
             class_name: "Authorization::AccountRole",
             foreign_key: :role_id,
             inverse_of: :role,
             dependent: :destroy

    normalizes :name, with: ->(name) { name.strip }

    validates :name, presence: true, uniqueness: { scope: :organization_id }

    scope :ordered, -> { order(:name) }

    def permission_keys = role_permissions.pluck(:permission_key)

    def has_permission?(key) = role_permissions.exists?(permission_key: key)
  end
end
