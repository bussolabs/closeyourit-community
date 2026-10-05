class CreateAlertingNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :alerting_notifications, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :project, type: :uuid, null: true,
                   foreign_key: { to_table: :projects, on_delete: :nullify }
      t.references :account, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :rule, type: :uuid, null: true,
                   foreign_key: { to_table: :alerting_rules, on_delete: :nullify }
      t.references :subject, type: :uuid, polymorphic: true, null: false

      t.integer  :via,         null: false
      t.integer  :event_type,  null: false
      t.string   :title,       null: false
      t.text     :body
      t.string   :url
      t.string   :dedup_key,   null: false
      t.integer  :status,      null: false, default: 0
      t.datetime :read_at
      t.datetime :delivered_at

      t.index %i[rule_id dedup_key], unique: true
      t.index %i[account_id read_at]
      t.index %i[organization_id created_at]
    end
  end
end
