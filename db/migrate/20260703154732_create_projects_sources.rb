# frozen_string_literal: true

# Fonte di telemetria OSSERVATA: un tool (SDK/agent) che ha realmente inviato dati al progetto, con
# l'ultima versione vista e l'ultimo istante di attività. Popolata in automatico dall'ingest
# (errori/metriche/log) via Projects::Source.track!. `tool_code` = il `sdk.name` del filo (QUALSIASI
# stringa: è telemetria, si registra ciò che arriva). Stesso pattern upsert di projects_releases.
class CreateProjectsSources < ActiveRecord::Migration[8.1]
  def change
    create_table :projects_sources, id: :uuid do |t|
      t.timestamps

      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }

      t.string :tool_code, null: false
      t.string :version
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.integer :events_count, null: false, default: 0

      t.index %i[project_id tool_code], unique: true
    end
  end
end
