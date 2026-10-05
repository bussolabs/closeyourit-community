class CreateAnalyticsPageviews < ActiveRecord::Migration[8.1]
  def change
    create_table :analytics_pageviews, id: :uuid do |t|
      # Immutabile: solo created_at (pattern logs_entries/metrics_samples).
      t.datetime :created_at, null: false

      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false

      t.string :event_id, null: false
      t.string :visitor_hash, null: false
      t.string :hostname, null: false
      t.string :path, null: false
      t.string :referrer_host
      t.string :browser
      t.string :os
      t.string :utm_source
      t.string :utm_medium
      t.string :utm_campaign
      t.string :environment
      t.datetime :occurred_at, null: false

      t.index %i[project_id event_id], unique: true
      t.index %i[project_id occurred_at], order: { occurred_at: :desc }
    end
  end
end
