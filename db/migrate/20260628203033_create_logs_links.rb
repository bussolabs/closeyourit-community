# frozen_string_literal: true

class CreateLogsLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :logs_links, id: :uuid do |t|
      t.timestamps

      # Chi ha creato il link manuale (audit). Nullify: l'account può essere cancellato, il link resta.
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.references :log_entry, type: :uuid, null: false,
                   foreign_key: { to_table: :logs_entries, on_delete: :cascade }
      # Target polimorfico: Errors::Group o Ticketing::Ticket (estensibile).
      t.references :linkable, polymorphic: true, type: :uuid, null: false

      t.index %i[log_entry_id linkable_type linkable_id], unique: true, name: "index_logs_links_unique"
    end
  end
end
