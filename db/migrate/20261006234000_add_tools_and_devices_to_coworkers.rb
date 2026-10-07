# Puckies reach the team's tools: connected apps, sites with a login, a screen a person can take
# over, procedures taught by example and the person's own computer
# (CYRA-1014, CYRA-1015, CYRA-1016, CYRA-1013, CYRA-1029).
class AddToolsAndDevicesToCoworkers < ActiveRecord::Migration[8.1]
  def change
    create_table :coworkers_connections, id: :uuid do |t|
      t.references :puck, type: :uuid, null: false, foreign_key: { to_table: :coworkers_puckies, on_delete: :cascade }
      t.string :provider, null: false
      t.string :name, null: false
      t.string :access, null: false, default: "read"
      t.string :url
      t.text :token
      t.jsonb :tools, null: false, default: []
      t.string :last_error
      t.timestamps
    end
    add_check_constraint :coworkers_connections, "provider IN ('github', 'mcp')", name: "coworkers_connections_provider_valid"
    add_check_constraint :coworkers_connections, "access IN ('read', 'write')", name: "coworkers_connections_access_valid"

    create_table :coworkers_sites, id: :uuid do |t|
      t.references :puck, type: :uuid, null: false, foreign_key: { to_table: :coworkers_puckies, on_delete: :cascade }
      t.string :domain, null: false
      t.text :username
      t.text :password
      t.timestamps
    end
    add_index :coworkers_sites, %i[puck_id domain], unique: true

    add_column :coworkers_runs, :control, :string
    add_column :coworkers_runs, :control_steps, :jsonb, null: false, default: []

    create_table :coworkers_procedures, id: :uuid do |t|
      t.references :puck, type: :uuid, null: false, foreign_key: { to_table: :coworkers_puckies, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: false, foreign_key: { to_table: :accounts }
      t.string :name, null: false
      t.text :steps, null: false
      t.timestamps
    end

    create_table :coworkers_devices, id: :uuid do |t|
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.datetime :last_seen_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :coworkers_devices, :token_digest, unique: true

    create_table :coworkers_device_calls, id: :uuid do |t|
      t.references :device, type: :uuid, null: false, foreign_key: { to_table: :coworkers_devices, on_delete: :cascade }
      t.references :run, type: :uuid, null: false, foreign_key: { to_table: :coworkers_runs, on_delete: :cascade }
      t.string :tool, null: false
      t.jsonb :arguments, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :coworkers_device_calls, "status IN ('pending', 'delivered', 'done', 'denied', 'failed', 'expired')",
      name: "coworkers_device_calls_status_valid"
  end
end
