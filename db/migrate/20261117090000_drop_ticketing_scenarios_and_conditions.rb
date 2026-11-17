# frozen_string_literal: true

require_relative "20261116230000_create_ticketing_acceptance_items"

# CYRA-1321 — scenarios and conditions live only in ticketing_acceptance_items since CYRA-1317; nothing reads or
# writes the old tables any more. Before dropping them, the rows an old container wrote while the release was
# rolling out are copied over (the same idempotent backfill, keyed on legacy_id), so nothing is lost.
# Rolling back recreates the empty tables only: the app reads the acceptance items, which stay.
class DropTicketingScenariosAndConditions < ActiveRecord::Migration[8.1]
  def up
    CreateTicketingAcceptanceItems.new.backfill
    drop_table :ticketing_scenarios
    drop_table :ticketing_conditions
  end

  def down
    create_table :ticketing_scenarios, id: :uuid do |t|
      t.timestamps
      t.references :ticket, type: :uuid, null: false,
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.integer :position, null: false, default: 0
      t.string :title
      t.text :step_given
      t.text :step_when
      t.text :step_then
      t.text :step_expected
      t.index %i[ticket_id position]
    end

    create_table :ticketing_conditions, id: :uuid do |t|
      t.timestamps
      t.references :ticket, type: :uuid, null: false,
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.integer :position, null: false, default: 0
      t.text :text, null: false
      t.index %i[ticket_id position]
    end
  end
end
