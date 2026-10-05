# frozen_string_literal: true

# Regole di raggruppamento personalizzate per progetto (CYRA-153): all'ingest rimappano il fingerprint
# di un'occorrenza che soddisfa un match, così errori che il grouping automatico terrebbe separati
# confluiscono in un unico gruppo (o viceversa). La PRIMA regola attiva, in ordine di position, vince.
class CreateErrorsGroupingRules < ActiveRecord::Migration[8.1]
  def change
    create_table :errors_grouping_rules, id: :uuid do |t|
      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      # exception_type / message / culprit / transaction (campo osservato dell'occorrenza)
      t.integer :field, null: false, default: 0
      # contains / equals / starts_with (niente regex: ReDoS sul path caldo)
      t.integer :operator, null: false, default: 0
      t.string :value, null: false, comment: "Pattern cercato nel campo osservato"
      t.string :fingerprint_key, null: false,
               comment: "Chiave logica: occorrenze con la stessa confluiscono nello stesso gruppo"
      t.timestamps
    end
    add_index :errors_grouping_rules, %i[project_id position]
  end
end
