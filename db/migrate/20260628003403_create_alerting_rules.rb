class CreateAlertingRules < ActiveRecord::Migration[8.1]
  def change
    create_table :alerting_rules, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :project, type: :uuid, null: true,
                   foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :environment, type: :uuid, null: true,
                   foreign_key: { to_table: :types_environments, on_delete: :nullify }

      t.string  :name,             null: false
      t.integer :event_type,       null: false
      t.integer :min_level,        null: true
      t.decimal :threshold_ms,     null: true
      t.integer :throttle_seconds, null: false, default: 300
      t.boolean :enabled,          null: false, default: true

      t.index %i[organization_id event_type enabled]
    end
  end
end
