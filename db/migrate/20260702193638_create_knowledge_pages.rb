# frozen_string_literal: true

class CreateKnowledgePages < ActiveRecord::Migration[8.1]
  def change
    # Knowledge base di progetto: pagine markdown (note/decisioni/guide) con embedding per la
    # ricerca semantica cross-progetto (stessa infra di ticketing_tickets/errors_groups).
    create_table :knowledge_pages, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts }, null: false

      t.references :project, type: :uuid, foreign_key: { to_table: :projects }, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.integer :kind, null: false, default: 0

      # Pipeline embedding (vedi Knowledge::EmbedPageJob): vettore + checksum versionato + istante.
      t.vector :embedding, limit: 1024
      t.string :embedding_checksum
      t.datetime :embedded_at

      t.index :kind
      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
    end
  end
end
