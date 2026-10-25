class CreateDashboardsFeeds < ActiveRecord::Migration[8.1]
  def change
    create_table :dashboards_feeds, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, index: { unique: true },
                             foreign_key: { to_table: :projects, on_delete: :cascade }
      t.string :url, null: false
      t.text :token, null: false
      t.boolean :enabled, null: false, default: true
      t.jsonb :payload
      t.datetime :fetched_at
      t.datetime :checked_at
      t.string :last_error
    end
  end
end
