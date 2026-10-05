# frozen_string_literal: true

# Voce di una lista di todo: titolo + fatto/non-fatto + posizione (riordinabile). Cade con la lista
# (on_delete: :cascade). Link OPZIONALE a un ticket (on_delete: :nullify: cancellando il ticket la
# voce sopravvive senza link). completed_at = istante in cui è stata spuntata (nil se non fatta).
class CreateTodosItems < ActiveRecord::Migration[8.1]
  def change
    create_table :todos_items, id: :uuid do |t|
      t.timestamps

      t.references :list, type: :uuid, null: false,
                   foreign_key: { to_table: :todos_lists, on_delete: :cascade }
      t.references :ticket, type: :uuid, null: true,
                   foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }

      t.string   :title, null: false
      t.boolean  :done, null: false, default: false
      t.integer  :position, null: false, default: 0
      t.datetime :completed_at
    end

    add_index :todos_items, %i[list_id position]
  end
end
