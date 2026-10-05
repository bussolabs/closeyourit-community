# frozen_string_literal: true

class CreateLogsEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :logs_entries, id: :uuid do |t|
      # Voce di log immutabile: solo created_at (nessun updated_at).
      t.datetime :created_at, null: false

      # project_id denormalizzato: retention/scoping/correlazione senza join.
      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }

      t.string   :event_id,    null: false   # id client (idempotenza at-least-once)
      t.integer  :level,       null: false, default: 1   # enum: debug/info/warning/error/fatal
      t.text     :message,     null: false
      t.jsonb    :data,        null: false, default: {}   # structured attributes (payload["attributes"] gemma)
      t.string   :logger_name                              # sorgente del log (payload["logger"])
      t.string   :trace_id                                 # correlazione per richiesta (log↔errori)
      t.string   :environment
      t.string   :release
      t.datetime :occurred_at, null: false

      t.index %i[project_id occurred_at], order: { occurred_at: :desc }   # stream principale
      t.index %i[project_id level]                                        # filtro livello
      t.index %i[project_id trace_id]                                     # correlazione
      t.index %i[project_id event_id], unique: true                       # idempotenza ingest
      t.index %i[project_id created_at]                                   # prune retention
    end
  end
end
