# frozen_string_literal: true

# Sottoscrizione di un account a un ticket: chi riceve le notifiche dei cambiamenti.
# organization_id denormalizzato (come Ticketing::Event) per lo scoping tenant delle notifiche.
# on_delete cascade su tutte le FK: una sottoscrizione è preferenza, non evidenza → muore col
# ticket, con l'account e con l'org. source = come ci si è iscritti (manual/reporter/assignee/...).
class CreateTicketingSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_subscriptions, id: :uuid do |t|
      t.timestamps

      t.references :ticket, type: :uuid, null: false,
                   foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.integer :source, null: false, default: 0
    end

    add_index :ticketing_subscriptions, %i[ticket_id account_id], unique: true
    add_index :ticketing_subscriptions, %i[organization_id account_id]
  end
end
