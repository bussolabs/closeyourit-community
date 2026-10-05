# frozen_string_literal: true

# CYRA-64: i tool di monitoring non si dichiarano più a mano — sono assunti automaticamente dalle
# chiamate ricevute (Projects::Source, sempre all'ultima versione vista) e la card mostra i soli
# osservati con la cronologia versioni. La tabella dell'ATTESO (Connections::ProjectTool) non serve
# più. Reversibile: il blocco descrive lo schema originale per un rollback pulito.
class DropConnectionsProjectTools < ActiveRecord::Migration[8.1]
  def change
    drop_table :connections_project_tools, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :platform, type: :uuid,
                   foreign_key: { to_table: :types_platforms, on_delete: :nullify }
      t.string :tool_code, null: false

      t.index %i[project_id tool_code], unique: true
    end
  end
end
