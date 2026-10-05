# frozen_string_literal: true

class CreateServersHostTokensAndActions < ActiveRecord::Migration[8.1]
  def change
    create_table :servers_host_tokens, id: :uuid do |t|
      t.references :host, type: :uuid, null: false, foreign_key: { to_table: :servers_hosts, on_delete: :cascade }
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :servers_host_tokens, :token_digest, unique: true
    add_index :servers_host_tokens, :host_id, unique: true, where: "revoked_at IS NULL",
              name: "index_servers_host_tokens_active_host"

    create_table :servers_actions, id: :uuid do |t|
      t.references :host, type: :uuid, null: false, foreign_key: { to_table: :servers_hosts, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.references :requested_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.string :kind, null: false
      t.integer :status, null: false, default: 0
      t.string :idempotency_key, null: false
      t.datetime :expires_at, null: false
      t.datetime :lease_expires_at
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :exit_code
      t.text :output
      t.text :error
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :servers_actions, %i[host_id idempotency_key], unique: true
    add_index :servers_actions, %i[host_id status created_at]
    add_index :servers_actions, :host_id, unique: true, where: "status IN (0, 1)",
              name: "index_servers_actions_one_active_per_host"
  end
end
