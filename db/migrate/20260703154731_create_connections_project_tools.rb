# frozen_string_literal: true

# Join progetto ↔ tool di monitoring ATTESO: dichiara quali SDK/agent un progetto si aspetta di
# ricevere (per segnalare in rosso quelli mai visti). `tool_code` = codice del registry Monitoring::Tool
# (NON una FK: il catalogo è dev-defined, costante). `platform_id` opzionale lega il tool a una
# piattaforma dichiarata (es. closeyourit-dart su ios). Stesso pattern di connections_project_platforms.
class CreateConnectionsProjectTools < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_project_tools, id: :uuid do |t|
      t.timestamps

      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :platform, type: :uuid, null: true,
                   foreign_key: { to_table: :types_platforms, on_delete: :nullify }

      t.string :tool_code, null: false

      t.index %i[project_id tool_code], unique: true
    end
  end
end
