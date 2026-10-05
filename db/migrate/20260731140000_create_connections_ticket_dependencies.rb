# frozen_string_literal: true

# Dipendenza direzionale ticket→ticket (CYRA-80): `ticket` DIPENDE da `blocker` (B è prerequisito
# di A). Clone del pattern connections_ticket_links, ma la direzione qui è semantica: il grafo dei
# blocker deve restare aciclico (difesa vera in transazione, vedi Connections::TicketDependency).
# on_delete cascade su ticket/blocker (la dipendenza è metadato, muore col ticket). created_by
# nullable + nullify: è attribuzione, non logica, e sopravvive alla cancellazione dell'account.
class CreateConnectionsTicketDependencies < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_ticket_dependencies, id: :uuid do |t|
      t.timestamps

      t.references :ticket, type: :uuid, null: false,
                   foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.references :blocker, type: :uuid, null: false,
                   foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.index %i[ticket_id blocker_id], unique: true
      # Un ticket non dipende da sé stesso: difesa DB-level oltre la validazione applicativa.
      t.check_constraint "ticket_id <> blocker_id", name: "connections_ticket_dependencies_not_self"
    end
  end
end
