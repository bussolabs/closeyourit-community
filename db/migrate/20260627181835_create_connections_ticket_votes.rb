# frozen_string_literal: true

# Voto (upvote) di un account su un ticket: un account vota un ticket una volta sola.
# Tenant-integrity validata sul model (account membro dell'org del ticket). on_delete cascade
# su entrambe le FK: un voto è opinione, non evidenza → muore col ticket e con l'account.
class CreateConnectionsTicketVotes < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_ticket_votes, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :ticket, type: :uuid, null: false,
                   foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
    end

    add_index :connections_ticket_votes, %i[account_id ticket_id], unique: true
  end
end
