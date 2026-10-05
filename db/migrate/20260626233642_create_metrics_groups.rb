# frozen_string_literal: true

class CreateMetricsGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :metrics_groups, id: :uuid do |t|
      t.timestamps

      # Cancellando il progetto, i suoi gruppi-metrica spariscono.
      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }

      t.string  :fingerprint, null: false   # chiave di deduplica (Metrics::Fingerprint)
      t.string  :title,       null: false   # SQL normalizzato / label metodo
      t.integer :kind,        null: false   # enum: slow_query/slow_method

      t.bigint   :samples_count, null: false, default: 0
      t.datetime :first_seen_at
      t.datetime :last_seen_at

      # Aggregati di durata (avg = total / count).
      t.float :duration_min_ms
      t.float :duration_max_ms
      t.float :duration_total_ms, null: false, default: 0.0

      t.index %i[project_id fingerprint], unique: true
      t.index %i[project_id kind last_seen_at]
    end
  end
end
