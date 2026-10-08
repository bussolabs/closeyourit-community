# frozen_string_literal: true

# CYRA-1052 — a Claude credential can belong to one machine, and can be pasted or linked from a vault secret.
class AddHostAndVaultLinksToAgentsClaudeCredentials < ActiveRecord::Migration[8.1]
  def change
    add_reference :agents_claude_credentials, :host, type: :uuid, null: true, index: { unique: true },
                  foreign_key: { to_table: :agents_hosts, on_delete: :cascade }
    add_reference :agents_claude_credentials, :personal_variable, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :secrets_personal_variables, on_delete: :cascade }
    add_reference :agents_claude_credentials, :shared_value, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :secrets_shared_values, on_delete: :cascade }

    change_column_null :agents_claude_credentials, :token, true
    change_column_null :agents_claude_credentials, :kind, true

    remove_index :agents_claude_credentials, :organization_id, unique: true
    add_index :agents_claude_credentials, :organization_id, unique: true, where: "host_id IS NULL",
              name: "index_agents_claude_credentials_on_organization_id_org_level"
    add_index :agents_claude_credentials, :organization_id
  end
end
