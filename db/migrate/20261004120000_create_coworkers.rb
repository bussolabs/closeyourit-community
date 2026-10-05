class CreateCoworkers < ActiveRecord::Migration[8.1]
  def change
    create_table :coworkers_dots, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { to_table: :organizations }
      t.references :account, type: :uuid, null: false, foreign_key: { to_table: :accounts }
      t.string :name, null: false
      t.text :instructions, null: false
      t.text :memory, null: false, default: ""
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :coworkers_runs, id: :uuid do |t|
      t.references :dot, type: :uuid, null: false, foreign_key: { to_table: :coworkers_dots }
      t.string :kind, null: false
      t.string :status, null: false, default: "queued"
      t.text :input, null: false
      t.text :output, null: false, default: ""
      t.jsonb :context, null: false, default: {}
      t.jsonb :tools, null: false, default: []
      t.string :error_code
      t.boolean :stop_requested, null: false, default: false
      t.datetime :started_at
      t.datetime :ended_at
      t.timestamps
    end
    add_index :coworkers_runs, [ :dot_id, :kind ], unique: true,
      where: "status IN ('queued', 'running')", name: "coworkers_active_lane"
  end
end
