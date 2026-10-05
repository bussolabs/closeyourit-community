# frozen_string_literal: true

class CreateErrorsEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :errors_events, id: :uuid do |t|
      # Evento immutabile: solo created_at (nessun updated_at).
      t.datetime :created_at, null: false

      t.references :group, type: :uuid, null: false,
                   foreign_key: { to_table: :errors_groups, on_delete: :cascade }
      # project_id denormalizzato: retention/scoping senza join sul gruppo.
      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }

      t.string   :event_id,   null: false   # event_id Sentry (idempotenza)
      t.datetime :occurred_at, null: false
      t.integer  :level                       # enum livello (come il gruppo)
      t.string   :environment
      t.string   :release
      t.string   :server_name
      t.string   :runtime                     # es. "ruby 3.3.10", "python 3.11"
      t.string   :user_hash                   # hash PII-safe dell'utente/IP

      t.jsonb :payload,    null: false, default: {}   # evento Sentry raw (lossless)
      t.jsonb :stacktrace, null: false, default: {}
      t.jsonb :context,    null: false, default: {}

      t.index %i[project_id event_id], unique: true   # idempotenza ingest
      t.index %i[group_id occurred_at]
      t.index %i[project_id created_at]                # prune retention
    end
  end
end
