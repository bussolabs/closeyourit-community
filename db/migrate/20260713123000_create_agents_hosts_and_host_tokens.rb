# frozen_string_literal: true

class CreateAgentsHostsAndHostTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_hosts, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :fingerprint, null: false
      t.string :hostname, null: false
      t.string :platform, null: false
      t.string :arch, null: false
      t.string :automator_version
      t.datetime :revoked_at
      t.timestamps

      t.index %i[organization_id fingerprint], unique: true
    end

    create_table :agents_host_tokens, id: :uuid do |t|
      t.references :host, type: :uuid, null: false,
                          foreign_key: { to_table: :agents_hosts, on_delete: :cascade }
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps

      t.index :token_digest, unique: true
      t.index :host_id, unique: true, where: "revoked_at IS NULL",
                        name: "index_agents_host_tokens_active_host"
    end
  end
end
