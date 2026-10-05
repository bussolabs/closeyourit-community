# frozen_string_literal: true

# Interruttore dedicato alla compattazione dei commenti (CYRA-222).
#
# Perché una chiave NUOVA e non il riuso di ai_ticket_composition_enabled: la compattazione è un
# backfill che spara centinaia di chiamate in fila, cioè esattamente la forma dell'incidente del
# 2026-07-29. Il god deve poter fermare il backfill senza spegnere la scrittura assistita che
# qualcuno sta usando in quel momento davanti allo schermo.
#
# Default true come le altre: la migration non cambia il comportamento di un'istanza già viva.
class AddAiCommentCompactionSwitch < ActiveRecord::Migration[8.1]
  def change
    add_column :settings_global, :ai_comment_compaction_enabled, :boolean, null: false, default: true
  end
end
