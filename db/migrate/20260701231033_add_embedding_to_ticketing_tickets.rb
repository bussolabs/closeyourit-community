class AddEmbeddingToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    change_table :ticketing_tickets, bulk: true do |t|
      t.datetime :embedded_at
      t.string   :embedding_checksum
      t.column   :embedding, :vector, limit: 1024
    end

    # I filtri RBAC riducono già molto lo scope: l'indice HNSW serve quando l'org cresce.
    add_index :ticketing_tickets, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
