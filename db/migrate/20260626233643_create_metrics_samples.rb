# frozen_string_literal: true

class CreateMetricsSamples < ActiveRecord::Migration[8.1]
  def change
    create_table :metrics_samples, id: :uuid do |t|
      # Sample immutabile: solo created_at (nessun updated_at).
      t.datetime :created_at, null: false

      t.references :group, type: :uuid, null: false,
                   foreign_key: { to_table: :metrics_groups, on_delete: :cascade }
      # project_id denormalizzato: retention/scoping senza join sul gruppo.
      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }

      t.integer  :kind,        null: false   # enum: slow_query/slow_method
      t.string   :sample_id,   null: false   # id client (idempotenza at-least-once)
      t.datetime :occurred_at, null: false
      t.float    :duration_ms, null: false
      t.string   :environment

      t.jsonb :payload, null: false, default: {}   # sql/name/db_system/file/lineno

      t.index %i[project_id sample_id], unique: true   # idempotenza ingest
      t.index %i[group_id occurred_at]
      t.index %i[project_id created_at]                # prune retention
    end
  end
end
