# frozen_string_literal: true

# CYRA-78 — override PER-PROGETTO della restrizione ambienti sui secret. La allow-list org-wide vive
# su Connections::Membership#secret_environment_codes (vale ovunque nell'org); qui si dichiara
# l'eccezione per un singolo progetto (es. "questa persona vede production SOLO su questo progetto").
# Precedenza risolta da Secrets::EnvironmentAccess: per-progetto > org-wide > nessuna restrizione.
# `organization_id` è denormalizzato dal progetto per il tenant guard e per gli scope di lettura.
class CreateConnectionsAccountSecretAccesses < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_account_secret_accesses, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.jsonb :environment_codes, null: false, default: []

      t.index %i[account_id project_id], unique: true
    end
  end
end
