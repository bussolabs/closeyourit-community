# frozen_string_literal: true

# Restrizione OPZIONALE degli environment su cui un account può accedere ai secret via CLI.
# Vuoto (default) = nessuna restrizione (tutti gli env dei progetti visibili). Usato dai service
# account per confinare l'accesso (es. "niente production"). Codici = Types::Environment#code dell'org.
class AddSecretEnvironmentCodesToMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :connections_memberships, :secret_environment_codes, :jsonb, null: false, default: []
  end
end
