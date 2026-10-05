# frozen_string_literal: true

module Authorization
  # Prefisso tabella del dominio: Authorization::Role → "authorization_roles", ecc.
  # (rules/rails/models.md). Senza, AR cercherebbe "roles"/"role_permissions".
  def self.table_name_prefix = "authorization_"
end
