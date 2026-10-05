class CreateAlertingPreferences < ActiveRecord::Migration[8.1]
  def change
    create_table :alerting_preferences, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }

      t.boolean :in_app_enabled, null: false, default: true
      t.boolean :email_enabled,  null: false, default: true
      t.boolean :errors_enabled, null: false, default: true
      t.boolean :uptime_enabled, null: false, default: true
      t.integer :min_level,      null: true
      t.integer :quiet_hours_start, null: true
      t.integer :quiet_hours_end,   null: true
      t.string  :quiet_hours_tz,    null: true
      t.integer :digest, null: false, default: 0

      t.index %i[organization_id account_id], unique: true
    end
  end
end
