# frozen_string_literal: true

class AddPublicationKeyToKnowledgePages < ActiveRecord::Migration[8.1]
  def change
    # Nullable per compatibilità con le pagine manuali/legacy. Solo le pagine gestite dal contratto
    # publish hanno una chiave, unica nel progetto; i titoli restano intenzionalmente duplicabili.
    add_column :knowledge_pages, :publication_key, :string
    add_index :knowledge_pages, %i[project_id publication_key], unique: true,
              where: "publication_key IS NOT NULL",
              name: "index_knowledge_pages_publication_identity"
  end
end
